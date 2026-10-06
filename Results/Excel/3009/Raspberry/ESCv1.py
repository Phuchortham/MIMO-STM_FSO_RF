# --- Standard library ---
import sys
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import time
import threading
import queue
import math
import re

# Flush print() eagerly so debug lines (FAN PWM init etc.) show up in tailed logs.
try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass

# --- Scientific / data / HTTP ---
import numpy as np
import pandas as pd
import requests

# --- Matplotlib embedded inside Tk ---
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
from matplotlib.figure import Figure

# --- Pi GPIO: two libraries on purpose ---
# gpiozero gives a clean RGBLED API; RPi.GPIO is needed for hardware PWM + raw digital pins.
import gpiozero as GPIO
import RPi.GPIO as RpiGPIO

# --- Environmental sensors ---
import adafruit_dht           # DHT11 + DHT22 temperature/humidity
import board                  # pin aliases (D4, D5, SCL, SDA, ...)
import busio                  # I2C bus for BMP280
import adafruit_bmp280        # BMP280 pressure/temp/altitude

# --- Camera + image processing ---
import cv2
from PIL import Image, ImageTk
from picamera2 import Picamera2

# Let OpenCV use its optimized SIMD paths and a small thread pool; cheap call,
# can noticeably speed up blur/threshold/contour ops on multi-core Pis.
cv2.setUseOptimized(True)
try:
    cv2.setNumThreads(2)
except Exception:
    pass


# =============================
# CONFIG
# All timings are in milliseconds unless the suffix says otherwise.
# =============================

# How often the Main tab logs a row, polls sensors, and redraws plots.
LOG_UPDATE_MS = 5000           # also the effective plot refresh rate (redraw is driven by insert_new_data)
SENSOR_UPDATE_MS = 5000
MAX_PLOT_POINTS = 200          # ring-buffer cap for the 4 live plots

# External APIs are rate-limited and slow-changing, so poll rarely.
WAQI_UPDATE_MS = 300000        # 5 min  — World Air Quality Index
QNH_UPDATE_MS = 600000         # 10 min — sea-level pressure from NZAA METAR
REQ_TIMEOUT_S = 8              # HTTP timeout (seconds)

# Legacy preview constants (kept for compatibility with earlier code paths).
PREVIEW_W, PREVIEW_H = 320, 160
CAM_UPDATE_MS = 15

# Camera capture resolution vs. on-screen display resolution.
# Capture is higher-res so the vision pipeline has detail; display is shrunk to fit the UI.
VIS_CAP_W = 640
VIS_CAP_H = 360
VIS_DISPLAY_W = 320
VIS_DISPLAY_H = 184
VIS_TAB_CAM_UPDATE_MS = 40     # camera capture cadence (~25 fps)
VIS_DISPLAY_UPDATE_MS = 100    # on-screen refresh cadence (~10 fps) — decoupled from capture
                               # because ImageTk.PhotoImage creation is the dominant UI cost.
VIS_FOCUS_UPDATE_MS = 500      # focus score recompute interval (cached between ticks)

# --- Defaults for the Visibility tab sliders ---
# These values were tuned for this physical rig (LED board + Pi camera distance).
VIS_DEFAULT_EXPOSURE_US = 4000   # short exposure so only bright LEDs show up
VIS_DEFAULT_GAIN = 1.0
VIS_DEFAULT_USE_ROI = True       # crop to the LED panel region before thresholding
VIS_DEFAULT_ROI_X1 = 210
VIS_DEFAULT_ROI_Y1 = 100
VIS_DEFAULT_ROI_X2 = 500
VIS_DEFAULT_ROI_Y2 = 355
VIS_DEFAULT_GRAY_THRESH = 165    # >= this grey level counts as "LED on"
VIS_DEFAULT_BLUR_K = 5           # Gaussian blur kernel before threshold
VIS_DEFAULT_MIN_AREA = 8         # ignore contours smaller than this (noise)
# Y-pixel positions of the manual distance reference lines drawn on the preview.
# Smaller Y = further from camera; these map pixel-Y to physical distance bands.
VIS_DEFAULT_LINE_50_Y = 300
VIS_DEFAULT_LINE_100_Y = 255
VIS_DEFAULT_LINE_150_Y = 210
VIS_DEFAULT_LINE_200_Y = 165


# =============================
# STATE
# All global state used by the GUI and worker threads lives here.
# =============================

# --- Data logging state (Main tab table) ---
row_index = 1                 # next row number to print in the table
is_collecting = False         # toggled by the Start/Stop button

# --- External API endpoints ---
API_KEY = 'f0569361ecdc14932a1543eb65f6193479b6bede'
url_WAQI = f'https://api.waqi.info/feed/here/?token={API_KEY}'
url_METAR = 'https://aviationweather.gov/api/data/metar?ids=NZAA&hours=1&order=id%2C-obs&sep=true'

# --- Latest "displayed" sensor values (what the big labels on the Main tab show) ---
temperature = math.nan
humidity = math.nan
pressure = math.nan
altitude = math.nan

# Current QNH (sea-level pressure reference). Updated by qnh_worker and
# read by sensor_worker to calibrate BMP280 altitude. Lock guards the read/write.
sea_pressure = 1013.25
sea_pressure_lock = threading.Lock()

# Last non-NaN means. Used to hold the previous good value on the display
# when a sensor read fails momentarily, instead of flashing "NaN".
last_good_mean_t = math.nan
last_good_mean_h = math.nan
last_good_mean_p = math.nan
last_good_mean_a = math.nan

# Rolling buffers for the 4 live plots on the Main tab.
plot_x = []
plot_t = []
plot_h = []
plot_p = []
plot_v = []

# Latest visibility analysis results, shared between tabs.
current_visibility_text = "-"
current_farthest_led_text = "-"


# =============================
# THREAD QUEUES (latest-only)
# Workers push snapshots here; the Tk main loop drains them via pollers.
# Capacity is tiny on purpose — we only care about the freshest reading.
# =============================
sensor_q = queue.Queue(maxsize=1)
weather_q = queue.Queue(maxsize=2)


def queue_put_latest(q: queue.Queue, item):
    """Put `item` in `q`, discarding the oldest entry if full.

    Non-blocking, so a slow UI thread can't stall the worker threads.
    """
    try:
        q.put_nowait(item)
    except queue.Full:
        # Drop the stale item, then try once more. If still full (unlikely
        # with maxsize=1), just give up — next tick will retry.
        try:
            _ = q.get_nowait()
        except queue.Empty:
            pass
        try:
            q.put_nowait(item)
        except queue.Full:
            pass


# =============================
# GPIO / DEVICES
# Hardware bring-up: RGB status LED, DHT sensors, BMP280 pair over I2C,
# PWM fan, and Peltier cool/heat relays.
# =============================

# RGB status LED — red on startup, flips to green while data collection is active.
led = GPIO.RGBLED(17, 27, 22)
led.color = (1, 0, 0)

# DHT11 is declared but not actively read — kept so it gets a .exit() on shutdown.
dht11_device = adafruit_dht.DHT11(board.D26)

# Single shared I2C bus for both BMP280 boards.
i2c = busio.I2C(board.SCL, board.SDA)

# Two BMP280 modules at standard addresses 0x76 and 0x77.
# If a board isn't physically present, store None so the worker can skip it gracefully.
bmp_sensors = []
for name, addr in [("BMP280-1 (0x76)", 0x76), ("BMP280-2 (0x77)", 0x77)]:
    try:
        dev = adafruit_bmp280.Adafruit_BMP280_I2C(i2c, address=addr)
    except Exception:
        dev = None
    bmp_sensors.append((name, dev))

# Three DHT22 sensors on dedicated GPIO pins.
# use_pulseio=False because pulseio isn't available on the Pi 5 / BCM2712.
DHT22_PINS = [
    ("DHT22 (1)", board.D4),
    ("DHT22 (2)", board.D5),
    ("DHT22 (3)", board.D6),
]
dht22_sensors = [(name, adafruit_dht.DHT22(pin, use_pulseio=False)) for name, pin in DHT22_PINS]

# --- Fan on hardware PWM ---
FAN_PIN = 13
RpiGPIO.setmode(RpiGPIO.BCM)
RpiGPIO.setup(FAN_PIN, RpiGPIO.OUT)


def init_fan_pwm(pin, preferred_hz=10000):
    """Start PWM on `pin`, falling back through slower frequencies if the preferred one fails.

    Some Pi firmware revisions reject very high PWM frequencies on software PWM,
    so we try a ladder and use the first one that sticks.
    """
    for hz in (preferred_hz, 8000, 5000, 2000, 1000):
        try:
            pwm = RpiGPIO.PWM(pin, hz)
            pwm.start(0)
            print(f"[FAN] PWM started at {hz} Hz")
            return pwm, hz
        except Exception as e:
            print(f"[FAN] PWM {hz} Hz failed: {e}")
    raise RuntimeError("No supported PWM frequency found")


fan_pwm, FAN_PWM_HZ = init_fan_pwm(FAN_PIN, preferred_hz=10000)

# --- Peltier element driven by two relays (one for cool direction, one for heat) ---
COOL_PIN = 23
HEAT_PIN = 16
RpiGPIO.setup(COOL_PIN, RpiGPIO.OUT)
RpiGPIO.setup(HEAT_PIN, RpiGPIO.OUT)
# Flip this if your relay board is active-low (HIGH = off).
PELTIER_ACTIVE_HIGH = True


# =============================
# HELPERS
# Small pure functions for NaN-safe stats and image buffer massaging.
# =============================

def xrgb_to_bgr(frame: np.ndarray) -> np.ndarray:
    """Drop the padding byte from picamera2's XRGB8888 buffer so OpenCV can use it as BGR."""
    if frame.ndim == 3 and frame.shape[2] == 4:
        return frame[:, :, :3]
    return frame


def _is_nan(v):
    """True for None or float NaN. Used everywhere since sensor reads can return either."""
    return v is None or (isinstance(v, float) and math.isnan(v))


def _good(vals):
    """Filter out NaNs/Nones from a list of sensor readings."""
    return [v for v in vals if not _is_nan(v)]


def mean_of(vals):
    """Return (mean, count_of_good_values). NaN mean when nothing is valid."""
    g = _good(vals)
    return (math.nan, 0) if not g else (sum(g) / len(g), len(g))


def spread_of(vals):
    """max - min across good values. NaN if fewer than 2 valid readings."""
    g = _good(vals)
    if len(g) < 2:
        return math.nan
    return max(g) - min(g)


def std_of(vals):
    """Population standard deviation (ddof=0) of good values."""
    g = _good(vals)
    if len(g) < 2:
        return math.nan
    return float(np.std(np.array(g), ddof=0))


def fmt_cell(v, ndp=1):
    """Format a float for a table cell, or return the literal string 'NaN'."""
    if _is_nan(v):
        return "NaN"
    return f"{v:.{ndp}f}"


def _to_float(x):
    """Best-effort float conversion; NaN on any failure (used for plot buffers)."""
    try:
        return float(x)
    except Exception:
        return math.nan


def _apply_last_good(v, last_good):
    """If `v` is NaN but we have a prior good value, show that instead — avoids UI flicker."""
    return last_good if _is_nan(v) and (not _is_nan(last_good)) else v


# =============================
# SENSOR READS
# Wrappers that never raise — they return NaN tuples instead so the aggregation
# layer can treat "missing" and "failed" readings uniformly.
# =============================

def safe_read_dht22(dev):
    """Return (temperature_C, humidity_%). (NaN, NaN) on any failure."""
    try:
        t = dev.temperature
        h = dev.humidity
        if t is None or h is None:
            return (math.nan, math.nan)
        return (float(t), float(h))
    except Exception:
        # DHT reads frequently raise RuntimeError on bit-timing errors — just drop the sample.
        return (math.nan, math.nan)


def safe_read_bmp(dev, qnh):
    """Return (temperature_C, pressure_hPa, altitude_m). (NaN, NaN, NaN) on any failure.

    `qnh` is fed in so altitude is computed against the current sea-level pressure.
    """
    if dev is None:
        return (math.nan, math.nan, math.nan)
    try:
        dev.sea_level_pressure = qnh
        t = dev.temperature
        p = dev.pressure
        a = dev.altitude
        if t is None or p is None or a is None:
            return (math.nan, math.nan, math.nan)
        return (float(t), float(p), float(a))
    except Exception:
        return (math.nan, math.nan, math.nan)


# =============================
# THREAD WORKERS
# Three daemon threads push snapshots into the queues; the Tk main loop reads them.
# They all check stop_event so on_close() can shut them down cleanly.
# =============================
stop_event = threading.Event()


def sensor_worker():
    """Read all DHT22 + BMP280 sensors, compute group statistics, push a snapshot.

    Repeats every SENSOR_UPDATE_MS. The snapshot dict bundles per-sensor rows,
    aggregate means/spread/std, and the "display" values (means with last-good fallback).
    """
    global last_good_mean_t, last_good_mean_h, last_good_mean_p, last_good_mean_a
    while not stop_event.is_set():
        # Grab the QNH once per cycle; qnh_worker updates it on a slower schedule.
        with sea_pressure_lock:
            qnh = float(sea_pressure)

        # Per-sensor rows keyed by friendly name — consumed by the Data tab table.
        dht_rows = {}
        bmp_rows = {}

        # Aggregate lists for stats. "all5" = 3 DHT22 + 2 BMP280 temperatures.
        temps_all5 = []
        hums_dht3 = []
        press_bmp2 = []
        alti_bmp2 = []

        # Read the 3 DHT22 sensors.
        for name, dev in dht22_sensors:
            t, h = safe_read_dht22(dev)
            dht_rows[name] = {"t": t, "h": h, "ok": (not _is_nan(t) and not _is_nan(h))}
            temps_all5.append(t)
            hums_dht3.append(h)

        # Read the 2 BMP280 sensors; `missing` flags boards that never initialised.
        for name, dev in bmp_sensors:
            t, p, a = safe_read_bmp(dev, qnh)
            missing = (dev is None)
            ok = (not _is_nan(t) and not _is_nan(p) and not _is_nan(a))
            bmp_rows[name] = {"t": t, "p": p, "a": a, "ok": ok, "missing": missing}
            temps_all5.append(t)
            press_bmp2.append(p)
            alti_bmp2.append(a)

        # Group statistics (NaN-aware).
        t_mean, t_ok = mean_of(temps_all5)
        rh_mean, rh_ok = mean_of(hums_dht3)
        p_mean, p_ok = mean_of(press_bmp2)
        a_mean, a_ok = mean_of(alti_bmp2)

        t_spread = spread_of(temps_all5)
        t_std = std_of(temps_all5)

        # Remember the latest good mean for each metric, so brief sensor glitches
        # don't blank out the big labels on the Main tab.
        if not _is_nan(t_mean):
            last_good_mean_t = t_mean
        if not _is_nan(rh_mean):
            last_good_mean_h = rh_mean
        if not _is_nan(p_mean):
            last_good_mean_p = p_mean
        if not _is_nan(a_mean):
            last_good_mean_a = a_mean

        # Display values fall back to last-good when the current read is NaN.
        t_disp = _apply_last_good(t_mean, last_good_mean_t)
        h_disp = _apply_last_good(rh_mean, last_good_mean_h)
        p_disp = _apply_last_good(p_mean, last_good_mean_p)
        a_disp = _apply_last_good(a_mean, last_good_mean_a)

        # Bundle everything into one immutable-ish snapshot the UI can apply atomically.
        snapshot = {
            "ts": time.time(),
            "qnh": qnh,
            "dht": dht_rows,
            "bmp": bmp_rows,
            "means": {
                "t_mean": t_mean, "t_ok": t_ok,
                "t_spread": t_spread,
                "t_std": t_std,
                "rh_mean": rh_mean, "rh_ok": rh_ok,
                "p_mean": p_mean, "p_ok": p_ok,
                "a_mean": a_mean, "a_ok": a_ok,
                "n_temp_good": len(_good(temps_all5)),
            },
            "main": {"t": t_disp, "h": h_disp, "p": p_disp, "a": a_disp},
        }

        queue_put_latest(sensor_q, snapshot)
        # stop_event.wait() is an interruptible sleep — exits immediately on shutdown.
        stop_event.wait(SENSOR_UPDATE_MS / 1000.0)


def qnh_worker():
    """Scrape NZAA METAR every 10 min for the current QNH (sea-level pressure).

    Used by sensor_worker to calibrate BMP280 altitude readings. Falls back to
    the ISA standard 1013.25 hPa if the fetch or regex match fails.
    """
    global sea_pressure
    while not stop_event.is_set():
        qnh_val = 1013.25   # ISA fallback
        err = None
        try:
            r = requests.get(url_METAR, timeout=REQ_TIMEOUT_S)
            if r.status_code == 200:
                text = r.text.strip()
                # METAR encodes QNH as "Qxxxx" where xxxx is pressure in hPa.
                m = re.search(r'Q(\d{4})', text)
                if m:
                    qnh_val = float(m.group(1))
        except Exception as e:
            err = str(e)

        with sea_pressure_lock:
            sea_pressure = qnh_val

        queue_put_latest(weather_q, {"type": "qnh", "qnh": qnh_val, "err": err})
        stop_event.wait(QNH_UPDATE_MS / 1000.0)


def waqi_worker():
    """Fetch the local air-quality feed (WAQI "here") every 5 min.

    Pushes a "waqi" message to weather_q with station name and the individual
    Iaqi (Instantaneous AQI) values for pressure, temp, humidity, wind, PM2.5.
    """
    while not stop_event.is_set():
        msg = {"type": "waqi", "ok": False}
        try:
            r = requests.get(url_WAQI, timeout=REQ_TIMEOUT_S)
            if r.status_code == 200:
                data = r.json()
                if data.get("status") == "ok":
                    iaqi = data["data"].get("iaqi", {})
                    # `.get("x", {}).get("v")` tolerates fields that this station doesn't report.
                    msg = {
                        "type": "waqi",
                        "ok": True,
                        "station": data["data"].get("city", {}).get("name", "Unknown"),
                        "p": iaqi.get("p", {}).get("v"),
                        "t": iaqi.get("t", {}).get("v"),
                        "h": iaqi.get("h", {}).get("v"),
                        "w": iaqi.get("w", {}).get("v"),
                        "wd": iaqi.get("wd", {}).get("v"),
                        "pm25": iaqi.get("pm25", {}).get("v"),
                    }
                else:
                    msg = {"type": "waqi", "ok": False, "err": "API status not ok"}
            else:
                msg = {"type": "waqi", "ok": False, "err": f"HTTP {r.status_code}"}
        except Exception as e:
            msg = {"type": "waqi", "ok": False, "err": str(e)}

        queue_put_latest(weather_q, msg)
        stop_event.wait(WAQI_UPDATE_MS / 1000.0)


# =============================
# PELTIER / FAN CONTROL
# Low-level helpers plus the button callbacks for the Main tab controls.
# =============================

def peltier_pin_on(pin):
    """Drive `pin` to its "on" level, respecting PELTIER_ACTIVE_HIGH polarity."""
    RpiGPIO.output(pin, RpiGPIO.HIGH if PELTIER_ACTIVE_HIGH else RpiGPIO.LOW)


def peltier_pin_off(pin):
    """Drive `pin` to its "off" level."""
    RpiGPIO.output(pin, RpiGPIO.LOW if PELTIER_ACTIVE_HIGH else RpiGPIO.HIGH)


def peltier_all_off():
    """Turn both cool and heat relays off. Called on shutdown and before mode changes."""
    peltier_pin_off(COOL_PIN)
    peltier_pin_off(HEAT_PIN)


def peltier_set_mode(mode: str):
    """Switch the Peltier between COOL / HEAT / OFF.

    The 0.2 s pause after turning both off guarantees relays settle and we never
    briefly energise both directions at once (which would short the H-bridge).
    """
    peltier_all_off()
    time.sleep(0.2)
    mode = (mode or "OFF").upper().strip()
    if mode == "COOL":
        peltier_pin_on(COOL_PIN)
    elif mode == "HEAT":
        peltier_pin_on(HEAT_PIN)
    else:
        mode = "OFF"
    peltier_status_var.set(f"Peltier: {mode}")


def set_peltier_mode_from_gui():
    """Radio-button callback: apply whatever mode is currently selected."""
    peltier_set_mode(peltier_mode_var.get())


def _fan_set(dc):
    """Set fan PWM duty cycle and grey out the button that matches it (visual feedback)."""
    fan_pwm.ChangeDutyCycle(dc)
    # Re-enable all buttons, then disable the one that's now the active setting.
    for b in (btn_FAN100, btn_FAN75, btn_FAN50, btn_FAN25, btn_FAN0):
        b.config(state="normal")
    if dc == 100:
        btn_FAN100.config(state="disabled")
    if dc == 75:
        btn_FAN75.config(state="disabled")
    if dc == 50:
        btn_FAN50.config(state="disabled")
    if dc == 25:
        btn_FAN25.config(state="disabled")
    if dc == 0:
        btn_FAN0.config(state="disabled")


# Thin button callbacks — one per duty cycle preset.
def fan_100():
    _fan_set(100)


def fan_75():
    _fan_set(75)


def fan_50():
    _fan_set(50)


def fan_25():
    _fan_set(25)


def fan_0():
    _fan_set(0)


# =============================
# SHARED CAMERA + MAIN TAB VIEW
# Picamera2 only allows one active instance per camera, so we wrap it in a
# single SharedCamera that both the Main tab preview and the Visibility tab
# analysis read from. It captures on a Tk `after()` loop (no extra thread).
# =============================
class SharedCamera:
    """Owns the single Picamera2 instance; exposes latest frame + metadata."""

    def __init__(self, parent):
        self.parent = parent            # Tk widget used to schedule the update loop
        self.picam2 = None
        self.running = False
        self.latest_bgr = None          # most recent captured frame in BGR (for OpenCV)
        self.latest_md = {}             # camera metadata (exposure, gain, ...)
        self.last_exp_us = None         # cached controls so we don't re-apply unchanged values
        self.last_gain = None
        self.last_meta_update = 0.0     # throttles metadata re-reads (expensive)

    def start(self):
        """Configure the sensor, start streaming, and kick off the capture loop."""
        if self.running:
            return
        try:
            self.picam2 = Picamera2()
            # RGB888 gives a 3-channel buffer (delivered in BGR byte order for OpenCV);
            # 25% less camera→RAM bandwidth than XRGB8888 and no padding-strip needed.
            # buffer_count=3 keeps memory modest without starving the capture loop.
            config = self.picam2.create_preview_configuration(
                main={"size": (VIS_CAP_W, VIS_CAP_H), "format": "RGB888"},
                buffer_count=3
            )
            self.picam2.configure(config)
            self.picam2.start()
            time.sleep(0.4)   # let AGC/AWB settle before consumers grab the first frame
            self.running = True
            self.update_loop()
        except Exception as e:
            print("Shared camera start error:", e)
            # Best-effort teardown so a partial init doesn't leak the camera device.
            self.running = False
            try:
                if self.picam2 is not None:
                    self.picam2.stop()
            except Exception:
                pass
            self.picam2 = None

    def stop(self):
        """Halt streaming and drop cached state. Safe to call multiple times."""
        self.running = False
        try:
            if self.picam2 is not None:
                self.picam2.stop()
        except Exception:
            pass
        self.picam2 = None
        self.latest_bgr = None
        self.latest_md = {}
        self.last_exp_us = None
        self.last_gain = None

    def is_running(self):
        return self.running and self.picam2 is not None

    def set_manual_controls(self, exposure_us, gain):
        """Apply manual exposure + gain (disables AE/AWB). No-op if values are unchanged."""
        if self.picam2 is None:
            return

        exposure_us = int(exposure_us)
        gain = float(gain)

        # Skip redundant calls — set_controls takes a frame or two to apply.
        if self.last_exp_us == exposure_us and self.last_gain == gain:
            return

        try:
            self.picam2.set_controls({
                "AeEnable": False,
                "AwbEnable": False,
                "ExposureTime": exposure_us,
                "AnalogueGain": gain,
            })
            self.last_exp_us = exposure_us
            self.last_gain = gain
        except Exception as e:
            print("Shared camera control apply error:", e)

    def update_loop(self):
        """Capture loop — grabs one frame and reschedules itself via Tk `after()`.

        Running it on the Tk thread keeps everything lock-free; consumers just
        read `latest_bgr`.
        """
        if not self.running or self.picam2 is None:
            return

        try:
            frame = self.picam2.capture_array("main")
            # `frame` aliases a picamera2-owned buffer that will be reused; copy once
            # so downstream consumers can hold onto `latest_bgr` safely. `xrgb_to_bgr`
            # is a no-op for RGB888 (3-channel) but kept so the format can change.
            self.latest_bgr = xrgb_to_bgr(frame).copy()
            


            # Metadata (exposure/gain as actually applied) updates twice a second — plenty for UI.
            now = time.time()
            if now - self.last_meta_update > 0.5:
                self.last_meta_update = now
                try:
                    self.latest_md = dict(self.picam2.capture_metadata())
                except Exception:
                    pass
        except Exception as e:
            print("Shared camera frame update error:", e)

        self.parent.after(VIS_TAB_CAM_UPDATE_MS, self.update_loop)

    def get_frame_copy(self):
        """Return the latest captured frame (or None). The buffer is already a dedicated
        copy owned by this object, and `vis_process_frame` copies on its own when it
        needs mutability, so no additional copy is needed here.
        """
        return self.latest_bgr

    def get_metadata(self):
        """Return a shallow copy of the latest camera metadata dict."""
        return dict(self.latest_md)


class MainLedPreviewBox:
    """Small dual-image preview on the Main tab (Original + Detection Overlay).

    Reads frames from SharedCamera and runs them through vis_process_frame using
    parameters the user configured on the Visibility tab (params_provider callback).
    """

    def __init__(self, parent, shared_camera, params_provider, x=780, y=320):
        self.shared_camera = shared_camera
        self.params_provider = params_provider   # usually VisibilityTabApp.get_params
        self.running = False

        self.container = tk.Frame(parent)
        self.container.place(x=x, y=y)

        left_box = tk.LabelFrame(self.container, text="Original", padx=4, pady=4)
        left_box.pack(side=tk.LEFT, padx=6)
        self.lbl_original = tk.Label(left_box, bg="black")
        self.lbl_original.pack()
        self.lbl_original.config(width=VIS_DISPLAY_W, height=VIS_DISPLAY_H)

        right_box = tk.LabelFrame(self.container, text="Detection Overlay", padx=4, pady=4)
        right_box.pack(side=tk.LEFT, padx=6)
        self.lbl_overlay = tk.Label(right_box, bg="black")
        self.lbl_overlay.pack()
        self.lbl_overlay.config(width=VIS_DISPLAY_W, height=VIS_DISPLAY_H)

        self._tk_original = None
        self._tk_overlay = None

    def start_view(self):
        """Begin the preview update loop (idempotent)."""
        if self.running:
            return
        self.running = True
        self.update()

    def stop_view(self):
        """Stop the preview loop — pending `after()` ticks exit on the `self.running` guard."""
        self.running = False

    def update(self):
        """One tick: grab the latest frame, run vision, update the two labels, reschedule."""
        global current_visibility_text, current_farthest_led_text

        if not self.running:
            return

        try:
            raw_bgr = self.shared_camera.get_frame_copy()
            if raw_bgr is not None:
                params = self.params_provider()
                # Main tab only shows original + overlay → run the fast pipeline
                # (full=False skips gray_bgr and bw_bgr build, plus the mask alloc).
                # Focus isn't displayed on this tab, so pass a zero override to skip
                # the Laplacian variance work entirely.
                original_view, _, _, overlay_bgr, detect_text, vis_text, _, _ = vis_process_frame(
                    raw_bgr, params, full=False, focus_override=0.0
                )

                # Publish visibility text globally so anything else can pick it up.
                current_farthest_led_text = detect_text
                current_visibility_text = vis_text
                update_visibility_label()

                # Keep the PhotoImage refs alive — Tk drops images whose Python handle is GC'd.
                self._tk_original = vis_resize_for_tk(original_view)
                self._tk_overlay = vis_resize_for_tk(overlay_bgr)

                self.lbl_original.config(image=self._tk_original)
                self.lbl_overlay.config(image=self._tk_overlay)
        except Exception as e:
            print("Main LED preview frame update error:", e)

        # Display cadence, not capture cadence (capture runs in SharedCamera.update_loop).
        self.container.after(VIS_DISPLAY_UPDATE_MS, self.update)


# =============================
# VISIBILITY TAB HELPERS
# Pure image-processing utilities shared by the vis pipeline.
# =============================

def vis_clamp_roi(x1, y1, x2, y2, w, h):
    """Clamp a bounding box to image bounds and enforce a minimum size (>= 6 px)."""
    x1 = max(0, min(w - 1, int(x1)))
    x2 = max(1, min(w, int(x2)))
    y1 = max(0, min(h - 1, int(y1)))
    y2 = max(1, min(h, int(y2)))

    # Don't let the user collapse the box to a line — blur/threshold hate empty ROIs.
    if x2 <= x1 + 5:
        x2 = min(w, x1 + 6)
    if y2 <= y1 + 5:
        y2 = min(h, y1 + 6)

    return x1, y1, x2, y2


def vis_odd_kernel(k):
    """Force an odd, >= 1 kernel size (GaussianBlur requires odd kernels)."""
    k = int(k)
    if k < 1:
        k = 1
    if k % 2 == 0:
        k += 1
    return k


def vis_clamp_y(y):
    """Clamp a Y-pixel to valid capture-image rows."""
    return max(0, min(VIS_CAP_H - 1, int(y)))


def vis_resize_for_tk(bgr_img):
    """Convert a BGR image to a Tk PhotoImage at display resolution (for label widgets)."""
    rgb = cv2.cvtColor(bgr_img, cv2.COLOR_BGR2RGB)
    rgb = cv2.resize(rgb, (VIS_DISPLAY_W, VIS_DISPLAY_H), interpolation=cv2.INTER_AREA)
    return ImageTk.PhotoImage(Image.fromarray(rgb))


def vis_sharpness_score(gray, x1, y1, x2, y2):
    """Laplacian variance of the ROI — a higher number means a sharper/more-in-focus image."""
    x1, y1, x2, y2 = vis_clamp_roi(x1, y1, x2, y2, gray.shape[1], gray.shape[0])
    roi = gray[y1:y2, x1:x2]
    if roi.size == 0:
        return 0.0
    return float(cv2.Laplacian(roi, cv2.CV_64F).var())


def vis_detect_led_regions(gray_full, roi_box, gray_thresh, blur_k, min_area, return_mask=True):
    """Find bright blobs inside `roi_box`. Returns (boxes, farthest_point, full_bw).

    - boxes: list of (x1, y1, x2, y2, area, cx, cy) in FULL-image coordinates
    - farthest_point: (cx, top_y) of the blob with the smallest top-Y (i.e. highest
      on screen → visually furthest down-range)
    - full_bw: the thresholded mask painted back into a full-size canvas, or None
      if the caller set `return_mask=False` (skips a zeros_like allocation per frame).
    """
    roi_x1, roi_y1, roi_x2, roi_y2 = roi_box
    roi = gray_full[roi_y1:roi_y2, roi_x1:roi_x2]

    if roi.size == 0:
        return [], None, None

    # Blur smooths speckle before hard thresholding.
    blur_k = vis_odd_kernel(blur_k)
    roi_blur = cv2.GaussianBlur(roi, (blur_k, blur_k), 0)

    # Simple fixed-threshold binarisation — the user tweaks the threshold live.
    _, roi_bw = cv2.threshold(roi_blur, gray_thresh, 255, cv2.THRESH_BINARY)
    contours, _ = cv2.findContours(roi_bw, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    boxes = []
    farthest_point = None
    smallest_top_y = 10**9      # sentinel larger than any image Y

    for cnt in contours:
        area = cv2.contourArea(cnt)
        if area < min_area:
            continue        # ignore specks — likely sensor noise, not an LED

        # Convert the contour's ROI-local rect back to full-image coordinates.
        x, y, w, h = cv2.boundingRect(cnt)
        gx1 = roi_x1 + x
        gy1 = roi_y1 + y
        gx2 = gx1 + w
        gy2 = gy1 + h
        cx = gx1 + w // 2
        cy = gy1 + h // 2

        boxes.append((gx1, gy1, gx2, gy2, area, cx, cy))

        # Smallest top-Y = highest on screen = furthest down-range in this rig.
        if gy1 < smallest_top_y:
            smallest_top_y = gy1
            farthest_point = (cx, gy1)

    # Paint the ROI mask back onto a full-size canvas for overlay rendering.
    # Skipped when the caller doesn't need the mask (Main-tab fast path).
    if return_mask:
        full_bw = np.zeros_like(gray_full)
        full_bw[roi_y1:roi_y2, roi_x1:roi_x2] = roi_bw
    else:
        full_bw = None

    return boxes, farthest_point, full_bw


def vis_draw_manual_distance_lines(img, params, x_left, x_right):
    """Draw the 4 coloured distance-reference lines (50/100/150/200 cm) on `img`."""
    line_data = [
        ("50 cm", vis_clamp_y(params["line_50_y"]), (0, 0, 255)),      # red
        ("100 cm", vis_clamp_y(params["line_100_y"]), (0, 165, 255)),  # orange
        ("150 cm", vis_clamp_y(params["line_150_y"]), (0, 255, 255)),  # yellow
        ("200 cm", vis_clamp_y(params["line_200_y"]), (0, 255, 0)),    # green
    ]

    for label, y, color in line_data:
        cv2.line(img, (x_left, y), (x_right, y), color, 2)
        text_y = max(18, y - 6)     # nudge label inside the frame if y is near the top
        cv2.putText(
            img, label, (x_left + 6, text_y),
            cv2.FONT_HERSHEY_SIMPLEX, 0.45, color, 2, cv2.LINE_AA
        )


def vis_classify_visibility_range(y_led, params):
    """Map the farthest-LED Y-position to a visibility band like '100-150 cm'.

    Distance lines may be dragged in any order on the sliders, so we sort by Y
    before comparing.
    """
    if y_led is None:
        return "Visibility range: no LED"

    # Pair each distance label with its current pixel Y, then sort top-to-bottom.
    line_points = [
        (50, vis_clamp_y(params["line_50_y"])),
        (100, vis_clamp_y(params["line_100_y"])),
        (150, vis_clamp_y(params["line_150_y"])),
        (200, vis_clamp_y(params["line_200_y"])),
    ]
    line_points = sorted(line_points, key=lambda item: item[1])

    # Above the topmost line → visibility is at least that far.
    if y_led < line_points[0][1]:
        return f"Visibility range: >= {line_points[0][0]} cm"

    # Between two lines → report the bounding band.
    for i in range(len(line_points) - 1):
        d1, y1 = line_points[i]
        d2, y2 = line_points[i + 1]
        if y1 <= y_led <= y2:
            low = min(d1, d2)
            high = max(d1, d2)
            return f"Visibility range: {low}-{high} cm"

    # Below the bottom line → closer than the shortest labelled distance.
    return f"Visibility range: < {line_points[-1][0]} cm"


def vis_process_frame(bgr, params, full=True, focus_override=None):
    """Full vision pipeline. Returns (original, gray_bgr, bw_bgr, overlay_bgr,
    detect_text, vis_text, focus_value, blob_count).

    `full=True`  → produce all 4 views (Visibility tab).
    `full=False` → skip gray_bgr / bw_bgr entirely; the Main-tab preview only needs
                   original + overlay, so this halves the per-frame compute.

    `focus_override` — if a number, skip the Laplacian variance computation and
    use the supplied cached value. Callers typically recompute focus every
    VIS_FOCUS_UPDATE_MS and pass the cached number between refreshes.

    Steps: grey → optional crop to ROI → blur → threshold → contours → pick the
    top-most blob as "farthest LED" → annotate views with ROI box, distance
    lines, blob rectangles, focus score, and visibility classification.
    """
    h, w = bgr.shape[:2]
    gray_full = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

    original_view = bgr.copy()
    # Only materialise the greyscale view when a caller will display it.
    gray_bgr = cv2.cvtColor(gray_full, cv2.COLOR_GRAY2BGR) if full else None

    # Use the user-specified ROI or fall back to the full frame.
    if params["use_roi"]:
        roi_x1, roi_y1, roi_x2, roi_y2 = vis_clamp_roi(
            params["roi_x1"], params["roi_y1"],
            params["roi_x2"], params["roi_y2"], w, h
        )
    else:
        roi_x1, roi_y1, roi_x2, roi_y2 = 0, 0, w, h

    roi_box = (roi_x1, roi_y1, roi_x2, roi_y2)

    # Core detection — skip the full-size mask canvas when we don't need the threshold view.
    boxes, farthest_point, bw_full = vis_detect_led_regions(
        gray_full, roi_box, params["gray_thresh"], params["blur_k"], params["min_area"],
        return_mask=full,
    )

    bw_bgr = cv2.cvtColor(bw_full, cv2.COLOR_GRAY2BGR) if (full and bw_full is not None) else None
    overlay = bgr.copy()

    # ROI box (yellow) drawn on the overlay always; on the mask view only when built.
    cv2.rectangle(overlay, (roi_x1, roi_y1), (roi_x2, roi_y2), (0, 255, 255), 2)
    if bw_bgr is not None:
        cv2.rectangle(bw_bgr, (roi_x1, roi_y1), (roi_x2, roi_y2), (0, 255, 255), 2)

    # Distance reference lines across the full ROI width.
    vis_draw_manual_distance_lines(overlay, params, roi_x1, roi_x2)
    if bw_bgr is not None:
        vis_draw_manual_distance_lines(bw_bgr, params, roi_x1, roi_x2)

    # Magenta box + area label around every detected blob (overlay only).
    for (x1, y1, x2, y2, area, cx, cy) in boxes:
        cv2.rectangle(overlay, (x1, y1), (x2, y2), (255, 0, 255), 2)
        cv2.putText(
            overlay,
            f"A={int(area)}",
            (x1, max(18, y1 - 6)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.45,
            (255, 0, 255),
            2,
            cv2.LINE_AA
        )

    # Defaults if no LED is visible this frame.
    detect_text = "Farthest LED: not detected"
    vis_text = "Visibility range: no LED"

    if farthest_point is not None:
        fx, fy = farthest_point

        # Highlight the farthest LED with a dot + horizontal guide line.
        cv2.circle(overlay, (fx, fy), 5, (255, 255, 255), -1)
        cv2.line(overlay, (roi_x1, fy), (roi_x2, fy), (255, 255, 255), 1)
        if bw_bgr is not None:
            cv2.circle(bw_bgr, (fx, fy), 5, (255, 255, 255), -1)
            cv2.line(bw_bgr, (roi_x1, fy), (roi_x2, fy), (255, 255, 255), 1)

        detect_text = f"Farthest LED at ({fx}, {fy})"
        vis_text = vis_classify_visibility_range(fy, params)

        # Green HUD text when an LED is found.
        cv2.putText(
            overlay,
            detect_text,
            (8, 24),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (0, 255, 0),
            2,
            cv2.LINE_AA
        )
    else:
        # Red HUD text when nothing passes the threshold.
        cv2.putText(
            overlay,
            "LED not detected",
            (8, 24),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (0, 0, 255),
            2,
            cv2.LINE_AA
        )

    # Focus indicator — use the cached override if the caller supplied one,
    # otherwise recompute the (relatively expensive) Laplacian variance.
    if focus_override is not None:
        focus_value = float(focus_override)
    else:
        focus_value = vis_sharpness_score(gray_full, roi_x1, roi_y1, roi_x2, roi_y2)

    cv2.putText(
        overlay,
        vis_text,
        (8, 48),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.55,
        (0, 255, 255),
        2,
        cv2.LINE_AA
    )

    # Focus readout is only useful when tuning on the Visibility tab; skip on the
    # Main-tab fast path to avoid a misleading "0.0" and save one putText call.
    if full:
        cv2.putText(
            overlay,
            f"Focus: {focus_value:.1f}",
            (8, 72),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (255, 255, 255),
            2,
            cv2.LINE_AA
        )

    return original_view, gray_bgr, bw_bgr, overlay, detect_text, vis_text, focus_value, len(boxes)


class VisibilityTabApp:
    """The Camera Visibility tab — builds the slider-heavy UI and drives vis_process_frame.

    Owns: the camera/detection sliders, the four preview labels (original, grey,
    threshold, overlay), camera start/stop buttons, and snapshot-to-JPG support.
    """

    def __init__(self, parent, shared_camera):
        self.parent = parent
        self.shared_camera = shared_camera
        self.running = False
        self.apply_job = None             # pending debounced `apply_camera_controls` after() id
        self.last_meta_update = 0
        self.last_focus_update = 0.0      # wall-clock timestamp of the last focus recompute

        # Remembered outputs from the most recent pipeline run — used by snapshot().
        self.last_bgr = None
        self.last_gray = None
        self.last_bw = None
        self.last_overlay = None
        self.last_focus_score = 0.0
        self.last_detect_text = "Farthest LED: -"
        self.last_vis_text = "Visibility range: -"

        self.main = tk.Frame(parent)
        self.main.pack(fill="both", expand=True, padx=10, pady=10)

        tk.Label(self.main, text="Camera Visibility Tool", font=("Arial", 16, "bold")).pack(pady=6)

        self.status_var = tk.StringVar(value="Status: Camera stopped")
        self.meta_var = tk.StringVar(value="Exposure: - | Gain: -")
        self.detect_var = tk.StringVar(value="Farthest LED: -")
        self.vis_var = tk.StringVar(value="Visibility range: -")
        self.focus_var = tk.StringVar(value="Focus score: -")
        self.count_var = tk.StringVar(value="Detected blobs: -")

        #tk.Label(self.main, textvariable=self.status_var, font=("Arial", 11)).pack()
        #tk.Label(self.main, textvariable=self.meta_var, font=("Arial", 10), fg="navy").pack(pady=1)
        #tk.Label(self.main, textvariable=self.detect_var, font=("Arial", 11, "bold"), fg="darkred").pack(pady=1)
        #tk.Label(self.main, textvariable=self.vis_var, font=("Arial", 11, "bold"), fg="darkblue").pack(pady=1)
        #tk.Label(self.main, textvariable=self.focus_var, font=("Arial", 10, "bold"), fg="darkgreen").pack(pady=1)
        #tk.Label(self.main, textvariable=self.count_var, font=("Arial", 10), fg="purple").pack(pady=1)

        #btns = tk.Frame(self.main)
        #btns.pack(pady=6)

        #tk.Button(btns, text="Start", width=10, command=self.start_camera).pack(side=tk.LEFT, padx=4)
        #tk.Button(btns, text="Apply", width=10, command=self.apply_camera_controls).pack(side=tk.LEFT, padx=4)
        #tk.Button(btns, text="Manual Low", width=12, command=self.set_manual_low_preset).pack(side=tk.LEFT, padx=4)
        #tk.Button(btns, text="Snapshot", width=10, command=self.snapshot).pack(side=tk.LEFT, padx=4)
        #tk.Button(btns, text="Stop", width=10, command=self.stop_camera).pack(side=tk.LEFT, padx=4)

        controls = tk.LabelFrame(self.main, text="Camera + Detection Controls")
        controls.pack(fill="x", padx=10, pady=6)

        row1 = tk.Frame(controls)
        row1.pack(fill="x", pady=2)

        self.exposure_var = tk.IntVar(value=VIS_DEFAULT_EXPOSURE_US)
        self.gain_var = tk.DoubleVar(value=VIS_DEFAULT_GAIN)
        self.thresh_var = tk.IntVar(value=VIS_DEFAULT_GRAY_THRESH)
        self.blur_var = tk.IntVar(value=VIS_DEFAULT_BLUR_K)
        self.min_area_var = tk.IntVar(value=VIS_DEFAULT_MIN_AREA)

        tk.Scale(row1, from_=500, to=15000, resolution=100, orient="horizontal",
                 label="Exposure us", variable=self.exposure_var, length=170,
                 command=self.on_camera_change).pack(side=tk.LEFT, padx=6)

        tk.Scale(row1, from_=1.0, to=8.0, resolution=0.1, orient="horizontal",
                 label="Gain", variable=self.gain_var, length=150,
                 command=self.on_camera_change).pack(side=tk.LEFT, padx=6)

        tk.Scale(row1, from_=0, to=255, resolution=1, orient="horizontal",
                 label="Gray Thresh", variable=self.thresh_var, length=150,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=6)

        tk.Scale(row1, from_=1, to=15, resolution=1, orient="horizontal",
                 label="Blur", variable=self.blur_var, length=120,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=6)

        tk.Scale(row1, from_=1, to=200, resolution=1, orient="horizontal",
                 label="Min Area", variable=self.min_area_var, length=120,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=6)

        row2 = tk.Frame(controls)
        row2.pack(fill="x", pady=2)

        self.use_roi_var = tk.BooleanVar(value=VIS_DEFAULT_USE_ROI)
        self.roi_x1_var = tk.IntVar(value=VIS_DEFAULT_ROI_X1)
        self.roi_y1_var = tk.IntVar(value=VIS_DEFAULT_ROI_Y1)
        self.roi_x2_var = tk.IntVar(value=VIS_DEFAULT_ROI_X2)
        self.roi_y2_var = tk.IntVar(value=VIS_DEFAULT_ROI_Y2)


        tk.Scale(row2, from_=0, to=VIS_CAP_W - 10, resolution=1, orient="horizontal",
                 label="X1", variable=self.roi_x1_var, length=110,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=4)

        tk.Scale(row2, from_=0, to=VIS_CAP_H - 10, resolution=1, orient="horizontal",
                 label="Y1", variable=self.roi_y1_var, length=110,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=4)

        tk.Scale(row2, from_=10, to=VIS_CAP_W, resolution=1, orient="horizontal",
                 label="X2", variable=self.roi_x2_var, length=110,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=4)

        tk.Scale(row2, from_=10, to=VIS_CAP_H, resolution=1, orient="horizontal",
                 label="Y2", variable=self.roi_y2_var, length=110,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=4)
        
        tk.Checkbutton(row2, text="Use ROI", variable=self.use_roi_var,
                       command=self.on_view_change).pack(side=tk.LEFT, padx=6)

        row3 = tk.LabelFrame(controls, text="Manual Threshold Lines (Y position only)")
        row3.pack(fill="x", padx=4, pady=4)

        self.line_50_var = tk.IntVar(value=VIS_DEFAULT_LINE_50_Y)
        self.line_100_var = tk.IntVar(value=VIS_DEFAULT_LINE_100_Y)
        self.line_150_var = tk.IntVar(value=VIS_DEFAULT_LINE_150_Y)
        self.line_200_var = tk.IntVar(value=VIS_DEFAULT_LINE_200_Y)

        tk.Scale(row3, from_=0, to=VIS_CAP_H - 1, resolution=1, orient="horizontal",
                 label="50 cm Y", variable=self.line_50_var, length=180,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=6)

        tk.Scale(row3, from_=0, to=VIS_CAP_H - 1, resolution=1, orient="horizontal",
                 label="100 cm Y", variable=self.line_100_var, length=180,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=6)

        tk.Scale(row3, from_=0, to=VIS_CAP_H - 1, resolution=1, orient="horizontal",
                 label="150 cm Y", variable=self.line_150_var, length=180,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=6)

        tk.Scale(row3, from_=0, to=VIS_CAP_H - 1, resolution=1, orient="horizontal",
                 label="200 cm Y", variable=self.line_200_var, length=180,
                 command=self.on_view_change).pack(side=tk.LEFT, padx=6)

        img_frame = tk.Frame(self.main)
        img_frame.pack(pady=6)

        box1 = tk.LabelFrame(img_frame, text="Original")
        box1.grid(row=0, column=0, padx=6, pady=6)
        self.lbl_original = tk.Label(box1, bg="black")
        self.lbl_original.pack()

        box2 = tk.LabelFrame(img_frame, text="Greyscale")
        box2.grid(row=0, column=1, padx=6, pady=6)
        self.lbl_gray = tk.Label(box2, bg="black")
        self.lbl_gray.pack()

        box3 = tk.LabelFrame(img_frame, text="Threshold")
        box3.grid(row=0, column=2, padx=6, pady=6)
        self.lbl_bw = tk.Label(box3, bg="black")
        self.lbl_bw.pack()

        box4 = tk.LabelFrame(img_frame, text="Detection Overlay")
        box4.grid(row=0, column=3, padx=6, pady=6)
        self.lbl_overlay = tk.Label(box4, bg="black")
        self.lbl_overlay.pack()

    def get_params(self):
        """Collect every slider/checkbox into a plain dict for vis_process_frame."""
        return {
            "exposure_us": self.exposure_var.get(),
            "gain": self.gain_var.get(),
            "use_roi": bool(self.use_roi_var.get()),
            "roi_x1": self.roi_x1_var.get(),
            "roi_y1": self.roi_y1_var.get(),
            "roi_x2": self.roi_x2_var.get(),
            "roi_y2": self.roi_y2_var.get(),
            "gray_thresh": self.thresh_var.get(),
            "blur_k": self.blur_var.get(),
            "min_area": self.min_area_var.get(),
            "line_50_y": self.line_50_var.get(),
            "line_100_y": self.line_100_var.get(),
            "line_150_y": self.line_150_var.get(),
            "line_200_y": self.line_200_var.get(),
        }

    def start_view(self):
        """Begin the per-frame update loop for this tab."""
        if self.running:
            return
        self.running = True
        self.refresh_status()
        self.update_frame()

    def stop_view(self):
        """Stop the per-frame update loop — pending `after()` ticks no-op on the guard."""
        self.running = False

    def refresh_status(self):
        """Update the 'Camera running/stopped' label from SharedCamera state."""
        if self.shared_camera.is_running():
            self.status_var.set("Status: Camera running")
        else:
            self.status_var.set("Status: Camera stopped")

    def on_camera_change(self, _=None):
        """Debounce exposure/gain slider drags — applies once the user stops moving (120 ms)."""
        if self.apply_job is not None:
            self.parent.after_cancel(self.apply_job)
        self.apply_job = self.parent.after(120, self.apply_camera_controls)

    def on_view_change(self, _=None):
        # Threshold/blur/ROI/line sliders don't need an explicit apply — the next
        # `update_frame` tick will read the current values.
        pass

    def set_manual_low_preset(self):
        """Reset every slider back to the VIS_DEFAULT_* constants and re-apply."""
        self.exposure_var.set(VIS_DEFAULT_EXPOSURE_US)
        self.gain_var.set(VIS_DEFAULT_GAIN)
        self.thresh_var.set(VIS_DEFAULT_GRAY_THRESH)
        self.blur_var.set(VIS_DEFAULT_BLUR_K)
        self.min_area_var.set(VIS_DEFAULT_MIN_AREA)

        self.use_roi_var.set(VIS_DEFAULT_USE_ROI)
        self.roi_x1_var.set(VIS_DEFAULT_ROI_X1)
        self.roi_y1_var.set(VIS_DEFAULT_ROI_Y1)
        self.roi_x2_var.set(VIS_DEFAULT_ROI_X2)
        self.roi_y2_var.set(VIS_DEFAULT_ROI_Y2)

        self.line_50_var.set(VIS_DEFAULT_LINE_50_Y)
        self.line_100_var.set(VIS_DEFAULT_LINE_100_Y)
        self.line_150_var.set(VIS_DEFAULT_LINE_150_Y)
        self.line_200_var.set(VIS_DEFAULT_LINE_200_Y)

        self.apply_camera_controls()

    def start_camera(self):
        """Start the shared camera and push current exposure/gain into it."""
        self.shared_camera.start()
        self.apply_camera_controls()
        self.refresh_status()

    def stop_camera(self):
        """Stop the shared camera (other tabs won't get frames until restarted)."""
        self.shared_camera.stop()
        self.refresh_status()

    def apply_camera_controls(self):
        """Send current exposure + gain to the camera. Called debounced or explicitly."""
        self.apply_job = None
        self.shared_camera.set_manual_controls(self.exposure_var.get(), self.gain_var.get())
        self.refresh_status()

    def update_metadata(self):
        """Refresh the 'Exposure / Gain' label from the latest camera metadata."""
        md = self.shared_camera.get_metadata()
        exp_us = md.get("ExposureTime", "-")
        gain = md.get("AnalogueGain", "-")
        self.meta_var.set(f"Exposure: {exp_us} us | Gain: {gain}")

    def update_frame(self):
        """Per-tick render of all 4 preview panes + text labels. Reschedules itself."""
        global current_visibility_text, current_farthest_led_text

        if not self.running:
            return

        try:
            raw_bgr = self.shared_camera.get_frame_copy()
            self.refresh_status()

            if raw_bgr is not None:
                # Only recompute the focus Laplacian every VIS_FOCUS_UPDATE_MS;
                # reuse the cached value in between to keep per-frame work small.
                now = time.time()
                recompute_focus = (now - self.last_focus_update) * 1000.0 >= VIS_FOCUS_UPDATE_MS
                focus_override = None if recompute_focus else self.last_focus_score

                original_view, gray_bgr, bw_bgr, overlay_bgr, detect_text, vis_text, focus_value, blob_count = vis_process_frame(
                    raw_bgr, self.get_params(), full=True, focus_override=focus_override
                )

                if recompute_focus:
                    self.last_focus_update = now

                self.last_bgr = original_view.copy()
                self.last_gray = gray_bgr.copy()
                self.last_bw = bw_bgr.copy()
                self.last_overlay = overlay_bgr.copy()
                self.last_detect_text = detect_text
                self.last_vis_text = vis_text
                self.last_focus_score = focus_value

                current_farthest_led_text = detect_text
                current_visibility_text = vis_text
                update_visibility_label()

                self.detect_var.set(detect_text)
                self.vis_var.set(vis_text)
                self.focus_var.set(f"Focus score: {focus_value:.1f}")
                self.count_var.set(f"Detected blobs: {blob_count}")

                self.tk_original = vis_resize_for_tk(original_view)
                self.tk_gray = vis_resize_for_tk(gray_bgr)
                self.tk_bw = vis_resize_for_tk(bw_bgr)
                self.tk_overlay = vis_resize_for_tk(overlay_bgr)

                self.lbl_original.config(image=self.tk_original)
                self.lbl_gray.config(image=self.tk_gray)
                self.lbl_bw.config(image=self.tk_bw)
                self.lbl_overlay.config(image=self.tk_overlay)

            now_meta = time.time()
            if now_meta - self.last_meta_update > 0.6:
                self.last_meta_update = now_meta
                self.update_metadata()

        except Exception as e:
            print("Visibility tab frame update error:", e)

        # Reschedule at the display cadence, NOT the capture cadence — capture keeps
        # running at VIS_TAB_CAM_UPDATE_MS inside SharedCamera.update_loop.
        self.parent.after(VIS_DISPLAY_UPDATE_MS, self.update_frame)

    def snapshot(self):
        """Save all 4 preview images to timestamped JPGs and pop a summary dialog."""
        if self.last_bgr is None:
            return

        ts = time.strftime("%Y%m%d_%H%M%S")
        cv2.imwrite(f"vis_orig_{ts}.jpg", self.last_bgr)
        if self.last_gray is not None:
            cv2.imwrite(f"vis_gray_{ts}.jpg", self.last_gray)
        if self.last_bw is not None:
            cv2.imwrite(f"vis_bw_{ts}.jpg", self.last_bw)
        if self.last_overlay is not None:
            cv2.imwrite(f"vis_overlay_{ts}.jpg", self.last_overlay)

        messagebox.showinfo(
            "Saved",
            f"Saved:\n"
            f"vis_orig_{ts}.jpg\n"
            f"vis_gray_{ts}.jpg\n"
            f"vis_bw_{ts}.jpg\n"
            f"vis_overlay_{ts}.jpg\n\n"
            f"{self.last_detect_text}\n"
            f"{self.last_vis_text}\n"
            f"Focus score = {self.last_focus_score:.1f}"
        )

# =============================
# GUI
# Root window, three-tab notebook, global Tk variables, and all widget setup.
# =============================
window = tk.Tk()
window.title('Env Chm (Threads + Queue)')
window.geometry('1600x800')
window.resizable(False, False)

# Shared Tk variables for the Peltier radio-group (lives on the root window).
peltier_mode_var = tk.StringVar(value="OFF")
peltier_status_var = tk.StringVar(value="Peltier: OFF")

# Three-tab layout: Main (live display), Data (per-sensor tables), Camera Visibility.
notebook = ttk.Notebook(window)
notebook.pack()

tab1 = ttk.Frame(notebook, borderwidth=2, relief="solid")
tab1.pack_propagate(False)
tab1.config(width=1500, height=600)

tab2 = ttk.Frame(notebook, borderwidth=2, relief="solid")
tab2.pack_propagate(False)
tab2.config(width=1500, height=600)

tab3 = ttk.Frame(notebook, borderwidth=2, relief="solid")
tab3.pack_propagate(False)
tab3.config(width=1500, height=760)

notebook.add(tab1, text='Main')
notebook.add(tab2, text='Data')
notebook.add(tab3, text='Camera Visibility')

style = ttk.Style()
style.configure("Custom.TFrame", background="lightgray")
tab1.configure(style="Custom.TFrame")

# Camera and view objects. Order matters: vis_app owns the sliders, so
# MainLedPreviewBox needs it to exist before it can ask for current params.
shared_camera = SharedCamera(window)
vis_app = VisibilityTabApp(tab3, shared_camera)
cam = MainLedPreviewBox(tab1, shared_camera, vis_app.get_params, x=780, y=320)

label_temp = tk.Label(tab1, text="NaN °C", font=("bold", 25), foreground="maroon")
label_temp.place(x=150, y=20)

label_humid = tk.Label(tab1, text="NaN %", font=("bold", 25), foreground="light coral")
label_humid.place(x=400, y=20)

label_pressure = tk.Label(tab1, text="NaN hPa", font=("bold", 25), foreground="DodgerBlue4")
label_pressure.place(x=650, y=20)

label_altitude = tk.Label(tab1, text="NaN m", font=("bold", 25), foreground="darkgreen")
label_altitude.place(x=900, y=20)

label_visibility = tk.Label(tab1, text="-", font=("bold", 22), foreground="purple")
label_visibility.place(x=1100, y=20)


def update_visibility_label():
    """Show the camera visibility band alongside the main sensor readings."""
    value = current_visibility_text.replace("Visibility range:", "", 1).strip()
    label_visibility.config(text=value)


def update_main_labels():
    """Sync the four big Main-tab readouts with the latest globals."""
    label_temp.config(text=f"{fmt_cell(temperature, 1)} °C")
    label_humid.config(text=f"{fmt_cell(humidity, 1)} %")
    label_pressure.config(text=f"{fmt_cell(pressure, 1)} hPa")
    label_altitude.config(text=f"{fmt_cell(altitude, 1)} m")
    update_visibility_label()


label_clock = tk.Label(window, text=" ")

label_sealevelW = tk.Label(window, text="QNH: ...")
label_titleW = tk.Label(window, text="Weather Stats", font=("Arial", 16))
label_stationW = tk.Label(window, text="@...")
label_pressureW = tk.Label(window, text="Pressure: ...")
label_temperatureW = tk.Label(window, text="Temperature: ...")
label_humidityW = tk.Label(window, text="Humidity: ...")
label_wind_speedW = tk.Label(window, text="Wind Speed: ...")
label_wind_dirW = tk.Label(window, text="Wind Direction: ...")
label_pm25W = tk.Label(window, text="PM2.5: ...")


def place_root_bottom_widgets():
    """Pin the weather labels, fan/peltier controls, clock and Start/Stop button.

    These widgets live on `window` (not inside any tab) so they stay visible
    under tab1 and tab2. When the Visibility tab is active we call
    hide_root_bottom_widgets() so they don't overlap the vision controls.
    """
    label_clock.place(x=1350, y=760)
    label_sealevelW.place(x=1000, y=760)
    label_titleW.place(x=1000, y=635)
    label_stationW.place(x=1150, y=640)
    label_pressureW.place(x=1000, y=670)
    label_temperatureW.place(x=1150, y=670)
    label_humidityW.place(x=1150, y=700)
    label_wind_speedW.place(x=1000, y=700)
    label_wind_dirW.place(x=1000, y=730)
    label_pm25W.place(x=1150, y=730)

    label_fan.place(x=60, y=720)
    btn_FAN100.place(x=60, y=740)
    btn_FAN75.place(x=140, y=740)
    btn_FAN50.place(x=220, y=740)
    btn_FAN25.place(x=300, y=740)
    btn_FAN0.place(x=380, y=740)

    label_peltier.place(x=60, y=690)
    peltier_radio_frame.place(x=100, y=690)

    btn_led.place(x=1400, y=720)


def hide_root_bottom_widgets():
    """Call `place_forget()` on all root-level widgets (used when switching to the Vis tab)."""
    for w in (
        label_clock, label_sealevelW, label_titleW, label_stationW, label_pressureW,
        label_temperatureW, label_humidityW, label_wind_speedW, label_wind_dirW,
        label_pm25W, label_fan, btn_FAN100, btn_FAN75, btn_FAN50, btn_FAN25, btn_FAN0,
        label_peltier, peltier_radio_frame, btn_led
    ):
        w.place_forget()


def clock():
    """Update the clock label every second. Self-rescheduling via Tk `after()`."""
    label_clock.config(text=time.strftime("%a, %d %b %Y %H:%M:%S"))
    window.after(1000, clock)


# --- Main-tab logging table (lower-left of tab1) ---
# Rows are appended by insert_new_data() while data collection is active.
table = ttk.Treeview(tab1, columns=('time', 'temp', 'humid', 'visi', 'press', 'alti'), height=10)
table.heading('time', text='Time')
table.heading('temp', text='Temperature(°C)')
table.heading('humid', text='Humidity(%)')
table.heading('visi', text='Visibility(cm)')
table.heading('press', text='Pressure(hPa)')
table.heading('alti', text='Altitude(m)')

table.column("#0", width=60)
table.column('time', width=80)
table.column('temp', width=140)
table.column('humid', width=120)
table.column('visi', width=120)
table.column('press', width=120)
table.column('alti', width=100)
table.place(x=20, y=320)

# --- Data tab: one row per physical sensor ---
label_env = tk.Label(tab2, text="Sensors", font=("Arial", 14, "bold"))
label_env.place(x=20, y=20)

env_table = ttk.Treeview(
    tab2,
    columns=("sensor", "temp", "hum", "press", "alti", "status"),
    show="headings",
    height=8
)
env_table.heading("sensor", text="Sensor")
env_table.heading("temp", text="Temp (°C)")
env_table.heading("hum", text="RH (%)")
env_table.heading("press", text="Pressure (hPa)")
env_table.heading("alti", text="Altitude (m)")
env_table.heading("status", text="Status")

env_table.column("sensor", width=220, anchor="w")
env_table.column("temp", width=120, anchor="center")
env_table.column("hum", width=120, anchor="center")
env_table.column("press", width=140, anchor="center")
env_table.column("alti", width=120, anchor="center")
env_table.column("status", width=120, anchor="center")
env_table.place(x=20, y=60)

# Pre-populate one row per sensor with em-dash placeholders; cells are filled
# in by poll_sensor_queue() as snapshots arrive.
env_row_ids = {}
for name, _ in dht22_sensors:
    env_row_ids[name] = env_table.insert("", "end", values=(name, "—", "—", "—", "—", "—"))
for name, _ in bmp_sensors:
    env_row_ids[name] = env_table.insert("", "end", values=(name, "—", "—", "—", "—", "—"))

# --- Data tab: aggregate statistics table, to the right of env_table ---
MEAN_X, MEAN_Y = 900, 60
label_mean = tk.Label(tab2, text="Mean Value", font=("Arial", 12, "bold"))
label_mean.place(x=MEAN_X, y=20)

mean_table = ttk.Treeview(
    tab2,
    columns=("metric", "value", "status"),
    show="headings",
    height=8
)
mean_table.heading("metric", text="Metric")
mean_table.heading("value", text="Value")
mean_table.heading("status", text="Status")

mean_table.column("metric", width=260, anchor="w")
mean_table.column("value", width=140, anchor="center")
mean_table.column("status", width=160, anchor="center")
mean_table.place(x=MEAN_X, y=MEAN_Y)

mean_row_ids = {}


def add_mean_row(key, metric_name):
    """Insert a stats row and remember its iid under `key` for later updates."""
    rid = mean_table.insert("", "end", values=(metric_name, "—", "—"))
    mean_row_ids[key] = rid


add_mean_row("T_MEAN_5", "Mean Temperature (°C)")
add_mean_row("T_SPREAD_5", "Temp Spread (°C)")
add_mean_row("T_STD_5", "Temp Std Dev (°C)")
add_mean_row("RH_MEAN_3", "Mean RH (%)")
add_mean_row("P_MEAN_2", "Mean Pressure (hPa)")
add_mean_row("A_MEAN_2", "Mean Altitude (m)")


def plot():
    """Build the temperature, humidity, pressure, and visibility plots on tab1."""
    global fig1, plot1, plot2, plot3, plot4, canvas
    global line1, line2, line3, line4

    fig1 = Figure(figsize=(14, 2), dpi=100)

    plot1 = fig1.add_subplot(141)
    plot2 = fig1.add_subplot(142)
    plot3 = fig1.add_subplot(143)
    plot4 = fig1.add_subplot(144)

    plot1.set_title("Temperature")
    plot1.set_ylim(0, 60)
    plot1.set_ylabel("°C")
    plot1.set_xlim(0, 10)
    line1, = plot1.plot([], [], color='maroon')

    plot2.set_title("Humidity")
    plot2.set_ylim(0, 100)
    plot2.set_ylabel("%")
    plot2.set_xlim(0, 10)
    line2, = plot2.plot([], [], color='coral')

    plot3.set_title("Pressure")
    plot3.set_ylim(900, 1100)
    plot3.set_ylabel("hPa")
    plot3.set_xlim(0, 10)
    line3, = plot3.plot([], [], color='navy')

    plot4.set_title("Visibility")
    plot4.set_ylim(0, 225)
    plot4.set_yticks([25, 75, 125, 175, 200])
    plot4.set_yticklabels(["<50", "50-100", "100-150", "150-200", ">=200"])
    plot4.set_ylabel("cm (band)")
    plot4.set_xlim(0, 10)
    line4, = plot4.plot([], [], color='darkgreen')

    fig1.subplots_adjust(wspace=0.5)

    canvas = FigureCanvasTkAgg(fig1, tab1)
    canvas.get_tk_widget().place(x=20, y=100)
    canvas.draw()


def redraw_plot():
    """Refresh the 4 plots from the rolling buffers. One-shot (no self-reschedule).

    Called from `insert_new_data` the moment a new sample is appended, so the
    plot reflects fresh readings immediately instead of waiting for a timer tick.
    """
    if not plot_x:
        return

    line1.set_data(plot_x, plot_t)
    line2.set_data(plot_x, plot_h)
    line3.set_data(plot_x, plot_p)
    line4.set_data(plot_x, plot_v)

    # Expand X range as the buffer grows, but never shrink below 10 ticks.
    xmax = max(10, len(plot_x))
    plot1.set_xlim(0, xmax)
    plot2.set_xlim(0, xmax)
    plot3.set_xlim(0, xmax)
    plot4.set_xlim(0, xmax)

    canvas.draw_idle()


def save_to_excel():
    """Export the current Main-tab table to an .xlsx file via a Save-As dialog."""
    items = table.get_children()
    if not items:
        print("No data to save.")
        return

    data = [table.item(it)['values'] for it in items]
    df = pd.DataFrame(
        data,
        columns=['Time', 'Temperature(°C)', 'Humidity(%)', 'Visibility(cm)', 'Pressure(hPa)', 'Altitude(m)']
    )

    filepath = filedialog.asksaveasfilename(
        defaultextension=".xlsx",
        filetypes=[("Excel files", "*.xlsx"), ("All files", "*.*")],
        title="Save As"
    )
    if filepath:
        df.to_excel(filepath, index=False)
        print(f"Saved to {filepath}")


def reset_table():
    """Clear the log table, plot buffers, and re-number future rows from 1."""
    global row_index
    for it in table.get_children():
        table.delete(it)
    row_index = 1

    plot_x.clear()
    plot_t.clear()
    plot_h.clear()
    plot_p.clear()
    plot_v.clear()

    line1.set_data([], [])
    line2.set_data([], [])
    line3.set_data([], [])
    line4.set_data([], [])
    canvas.draw_idle()


btn_reset = tk.Button(tab1, text="Reset", command=reset_table)
btn_reset.place(x=550, y=550)

btn_save = tk.Button(tab1, text="Save", command=save_to_excel)
btn_save.place(x=620, y=550)

btn_text = tk.StringVar(value="Start")


def visibility_band_plot_value(value):
    """Represent a visibility band in cm; missing detection leaves a gap."""
    try:
        if value.startswith(">="):
            return float(value[2:].strip())  # lower bound of an open-ended band
        if value.startswith("<"):
            return float(value[1:].strip()) / 2  # midpoint from zero
        low, high = value.split("-", 1)
        return (float(low) + float(high)) / 2
    except (ValueError, AttributeError):
        return math.nan


def insert_new_data():
    """Append the latest sensor values as a new Main-tab table row and plot point.

    Self-reschedules every LOG_UPDATE_MS while `is_collecting` is True. Stops
    automatically when the user clicks Stop (is_collecting flips to False).
    """
    global row_index

    if not is_collecting:
        return

    ts = time.strftime("%H:%M:%S")

    # Extract only the range/value for the Visibility(cm) column
    visibility_value = current_visibility_text.replace(
        "Visibility range:", ""
    ).replace(" cm", "").strip()

    new_item = table.insert(
        parent='',
        index=tk.END,
        text=str(row_index),
        values=(
            ts,
            fmt_cell(temperature, 2),
            fmt_cell(humidity, 2),
            visibility_value,
            fmt_cell(pressure, 2),
            fmt_cell(altitude, 2)
        )
    )

    table.see(new_item)
    row_index += 1

    plot_x.append(len(plot_x) + 1)
    plot_t.append(_to_float(temperature))
    plot_h.append(_to_float(humidity))
    plot_p.append(_to_float(pressure))
    plot_v.append(visibility_band_plot_value(visibility_value))

    # Trim the rolling plot buffer and renumber X so the plot always starts at 1.
    if len(plot_x) > MAX_PLOT_POINTS:
        plot_x.pop(0)
        plot_t.pop(0)
        plot_h.pop(0)
        plot_p.pop(0)
        plot_v.pop(0)

        for i in range(len(plot_x)):
            plot_x[i] = i + 1

    redraw_plot()

    # IMPORTANT: keeps monitoring continuously
    window.after(LOG_UPDATE_MS, insert_new_data)


def update_btn_led_text():
    """Start/Stop toggle: flips the button text, RGB LED colour, and is_collecting flag."""
    global is_collecting
    if btn_text.get() == "Start":
        btn_text.set("Stop")
        led.color = (0, 1, 0)       # green while collecting
        is_collecting = True
        insert_new_data()
    else:
        btn_text.set("Start")
        led.color = (1, 0, 0)       # red when idle
        is_collecting = False


btn_led = tk.Button(window, textvariable=btn_text, command=update_btn_led_text)

label_fan = tk.Label(window, text=f"PWM Fan")
btn_FAN100 = tk.Button(window, text="100%", command=fan_100)
btn_FAN75 = tk.Button(window, text="75%", command=fan_75)
btn_FAN50 = tk.Button(window, text="50%", command=fan_50)
btn_FAN25 = tk.Button(window, text="25%", command=fan_25)
btn_FAN0 = tk.Button(window, text="0%", command=fan_0)
btn_FAN0.config(state="disabled")

label_peltier = tk.Label(window, text="Peltier")
peltier_radio_frame = tk.Frame(window)

tk.Radiobutton(peltier_radio_frame, text="COOL", variable=peltier_mode_var, value="COOL",
               command=set_peltier_mode_from_gui).pack(side="left", padx=6)
tk.Radiobutton(peltier_radio_frame, text="HEAT", variable=peltier_mode_var, value="HEAT",
               command=set_peltier_mode_from_gui).pack(side="left", padx=6)
tk.Radiobutton(peltier_radio_frame, text="OFF", variable=peltier_mode_var, value="OFF",
               command=set_peltier_mode_from_gui).pack(side="left", padx=6)

place_root_bottom_widgets()


# =============================
# QUEUE POLLERS
# Bridge from worker threads into Tk: Tkinter is NOT thread-safe, so workers
# push into a queue and these pollers drain the queue from the main loop.
# =============================

def poll_sensor_queue():
    """Drain every available sensor snapshot and update all on-screen widgets.

    Self-reschedules every 100 ms. The inner `while True` keeps pulling until
    the queue is empty — important since workers may have queued newer data
    while the UI was busy repainting.
    """
    global temperature, humidity, pressure, altitude
    try:
        while True:
            snap = sensor_q.get_nowait()

            temperature = snap["main"]["t"]
            humidity = snap["main"]["h"]
            pressure = snap["main"]["p"]
            altitude = snap["main"]["a"]

            update_main_labels()

            for name, r in snap["dht"].items():
                rid = env_row_ids[name]
                env_table.set(rid, "temp", fmt_cell(r["t"], 1))
                env_table.set(rid, "hum", fmt_cell(r["h"], 1))
                env_table.set(rid, "press", "—")
                env_table.set(rid, "alti", "—")
                env_table.set(rid, "status", "OK" if r["ok"] else "NaN")

            for name, r in snap["bmp"].items():
                rid = env_row_ids[name]
                env_table.set(rid, "temp", fmt_cell(r["t"], 1))
                env_table.set(rid, "hum", "—")
                env_table.set(rid, "press", fmt_cell(r["p"], 2))
                env_table.set(rid, "alti", fmt_cell(r["a"], 2))
                if r["missing"]:
                    st = "MISSING"
                else:
                    st = "OK" if r["ok"] else "NaN"
                env_table.set(rid, "status", st)

            # Aggregate means / spread / std — each row shows value + how many
            # sensors contributed ("OK (4/5)" etc.).
            m = snap["means"]
            mean_table.set(mean_row_ids["T_MEAN_5"], "value", fmt_cell(m["t_mean"], 2))
            mean_table.set(mean_row_ids["T_MEAN_5"], "status", f"OK ({m['t_ok']}/5)" if m["t_ok"] > 0 else "NO DATA")

            mean_table.set(mean_row_ids["T_SPREAD_5"], "value", fmt_cell(m["t_spread"], 2))
            mean_table.set(mean_row_ids["T_SPREAD_5"], "status", f"OK ({m['n_temp_good']}/5)" if m["n_temp_good"] >= 2 else "NEED ≥2")

            mean_table.set(mean_row_ids["T_STD_5"], "value", fmt_cell(m["t_std"], 2))
            mean_table.set(mean_row_ids["T_STD_5"], "status", f"OK ({m['n_temp_good']}/5)" if m["n_temp_good"] >= 2 else "NEED ≥2")

            mean_table.set(mean_row_ids["RH_MEAN_3"], "value", fmt_cell(m["rh_mean"], 2))
            mean_table.set(mean_row_ids["RH_MEAN_3"], "status", f"OK ({m['rh_ok']}/3)" if m["rh_ok"] > 0 else "NO DATA")

            mean_table.set(mean_row_ids["P_MEAN_2"], "value", fmt_cell(m["p_mean"], 2))
            mean_table.set(mean_row_ids["P_MEAN_2"], "status", f"OK ({m['p_ok']}/2)" if m["p_ok"] > 0 else "NO DATA")

            mean_table.set(mean_row_ids["A_MEAN_2"], "value", fmt_cell(m["a_mean"], 2))
            mean_table.set(mean_row_ids["A_MEAN_2"], "status", f"OK ({m['a_ok']}/2)" if m["a_ok"] > 0 else "NO DATA")

    except queue.Empty:
        pass

    window.after(100, poll_sensor_queue)


def poll_weather_queue():
    """Drain weather_q and update the QNH + WAQI labels on the Main tab."""
    try:
        while True:
            msg = weather_q.get_nowait()
            if msg.get("type") == "qnh":
                qnh = msg.get("qnh", 1013.25)
                label_sealevelW.config(text=f"QNH: {qnh:.1f} hPa (NZAA METAR)")
            elif msg.get("type") == "waqi":
                if msg.get("ok"):
                    label_stationW.config(text=f"@ {msg.get('station', 'Unknown')}")
                    label_pressureW.config(text=f"Pressure: {msg.get('p')} hPa" if msg.get("p") is not None else "Pressure: N/A")
                    label_temperatureW.config(text=f"Temperature: {msg.get('t')} °C" if msg.get("t") is not None else "Temperature: N/A")
                    label_humidityW.config(text=f"Humidity: {msg.get('h')} %" if msg.get("h") is not None else "Humidity: N/A")
                    label_wind_speedW.config(text=f"Wind Speed: {msg.get('w')} m/s" if msg.get("w") is not None else "Wind Speed: N/A")
                    label_wind_dirW.config(text=f"Wind Direction: {msg.get('wd')}°" if msg.get("wd") is not None else "Wind Direction: N/A")
                    label_pm25W.config(text=f"PM2.5: {msg.get('pm25')} µg/m³" if msg.get("pm25") is not None else "PM2.5: N/A")
                else:
                    label_stationW.config(text="@ WAQI error")
    except queue.Empty:
        pass

    window.after(200, poll_weather_queue)


# =============================
# TAB CHANGE / CLOSE
# Lifecycle for view loops + final hardware teardown on window close.
# =============================

def on_tab_changed(event=None):
    """Start/stop the Main and Visibility view loops so only the visible tab is rendering.

    Also shows/hides the root-level weather and control widgets so they don't
    overlap the Visibility tab's dense controls.
    """
    selected = window.nametowidget(notebook.select())
    try:
        if selected == tab1:
            # Main tab: small LED preview on, full visibility view off.
            place_root_bottom_widgets()
            cam.start_view()
            vis_app.stop_view()
        elif selected == tab3:
            # Visibility tab: full 4-image view on, small preview off.
            hide_root_bottom_widgets()
            cam.stop_view()
            vis_app.start_view()
        else:
            # Data tab (or anything else): both previews off to save CPU.
            place_root_bottom_widgets()
            cam.stop_view()
            vis_app.stop_view()
    except Exception as e:
        print("Tab change view error:", e)


notebook.bind("<<NotebookTabChanged>>", on_tab_changed)


def start_initial_tab():
    """One-shot bootstrap: open the camera, load defaults, show the Visibility tab."""
    shared_camera.start()
    vis_app.set_manual_low_preset()
    notebook.select(tab3)
    on_tab_changed()


def on_close():
    """Clean shutdown on window close — every step is guarded so one failure
    can't prevent the rest from running.

    Order matters: signal workers to stop → stop camera views → close camera
    → de-energise Peltier → stop fan PWM → release sensors → clean GPIO → destroy window.
    """
    stop_event.set()  # unblocks all worker threads' interruptible sleeps

    try:
        vis_app.stop_view()
    except Exception:
        pass

    try:
        cam.stop_view()
    except Exception:
        pass

    try:
        shared_camera.stop()
    except Exception:
        pass

    # SAFETY: always de-energise the Peltier before exit.
    try:
        peltier_all_off()
    except Exception:
        pass

    try:
        fan_pwm.ChangeDutyCycle(0)
        fan_pwm.stop()
    except Exception:
        pass

    try:
        dht11_device.exit()
    except Exception:
        pass

    # Call .exit() on each DHT22 so the GPIO is released for the next process.
    try:
        for _, dev in dht22_sensors:
            try:
                dev.exit()
            except Exception:
                pass
    except Exception:
        pass

    try:
        RpiGPIO.cleanup()
    except Exception:
        pass

    window.destroy()


window.protocol("WM_DELETE_WINDOW", on_close)


# =============================
# START EVERYTHING
# Build plot + clock → spawn worker threads → schedule pollers → open initial tab.
# =============================
plot()
clock()

# Daemon threads so they die with the process if on_close() is bypassed (e.g. Ctrl+C).
threading.Thread(target=sensor_worker, daemon=True).start()
threading.Thread(target=qnh_worker, daemon=True).start()
threading.Thread(target=waqi_worker, daemon=True).start()

# All poll/plot loops are kicked off on the Tk main thread via after().
# NOTE: no standalone plot timer — `insert_new_data` calls `redraw_plot()` each
# time a fresh sample lands, so the graph updates immediately on new data.
window.after(0, poll_sensor_queue)
window.after(0, poll_weather_queue)
window.after(300, start_initial_tab)   # 300 ms delay lets the GUI draw once before the camera spin-up

window.mainloop()
