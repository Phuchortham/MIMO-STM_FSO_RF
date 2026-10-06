# V3.3 - Measured Optical Delivery

A separate source-test candidate based on V3.2. The supplied Designer is preserved
byte-for-byte: names, headings, column order, widths, frozen columns and layout.
V3.1, V3.2 and the live FPGA project were not edited or programmed.

This version adds measured optical delivery. It does not claim hardware timing
closure or verified 100 Mbps operation. Read VALIDATION.md before using the RTL.

## Install in copies of the working projects

1. Copy the working V3.2 C# project and the working Quartus project.
2. Replace Form1.cs in the C# copy. Include all eight production files:
   Form1.cs, Form1.RfBackup.cs, RfBackupCoordinator.cs, RfProtocol.cs,
   RfLinkController.cs, RfSerialEndpoint.cs, Form1.DeliveryMetrics.cs,
   and DeliveryMetrics.cs.
3. Keep your real FT601 references/drivers, Program.cs and Form1.resx. The supplied
   Form1.Designer.cs is exactly your attachment; if already installed, keep it.
   A no-op label14_Click handler was added in the partial class to satisfy the
   event wiring in your Designer without changing it. Do not install test mocks.
4. In the Quartus COPY, use the supplied complete FSOx86.v. The passive monitor
   is appended inside that same file; no extra Verilog project file is required.
   Keep existing top-level name, PLL, pin assignments and constraints. Compile
   and inspect timing before considering a hardware test; no SOF is supplied.
5. C# uses the existing .NET Framework WinForms project, C# 7.3+, System,
   System.Core, System.Drawing and System.Windows.Forms. A complete build against
   your native FT601 library and physical testbed remains a bench task.

The new C# can still read legacy optical status. Without the matching V3.3 FPGA,
RX1/RX2 measured line rates can be shown, but output metrics show Unavailable.
This is intentional: blank measurement hardware must never become estimated
goodput or an invented delivery percentage.

## Your existing eleven columns

The original six values stay in the same order: Time, Mode, FSO-BER1, FSO-BER2,
FSO-ABER, RF-BER. New cells are addressed by their existing control names:

| Existing heading / Name | Value and units |
|---|---|
| Rx1 | RX1 checked optical line bits per second, displayed in Mbps |
| Rx2 | RX2 checked optical line bits per second, displayed in Mbps |
| OBER | Errors / compared decoded optical output bits for the latest interval |
| Throughput | Correct, complete, unique optical payload goodput in Mbps |
| Delivery | Correct complete source blocks / expected source blocks, percent |

No heading was renamed. In particular, Throughput contains GOODPUT, not the
configured link rate. Throughput and Delivery retain six decimals so a small
measured loss is not hidden by coarse rounding. Column width/layout is unchanged;
CSV preserves the full numeric strings even when a cell is visually truncated.

SISO uses the same FPGA measurements and records them in the existing Data-tab
log. The Data-tab three-column table is not changed, and SISO adds no MIMO rows.

## Measurement definition

The fixed logical block is 32 original source bytes (256 information bits),
regardless of message length, coding or optical spatial mode:

- SISO: 32 consecutive selected RX1 decoded bytes.
- DIV: 32 consecutive decoded bytes from the actual selected receiver path.
  Receiving both copies does not double the useful output.
- SMP: 16 consecutive accepted byte pairs from the actual existing SMP
  reconstruction path. Both lane bytes are required for each source pair.

The observer records original bytes at the actual encoder-load edge, tagged by
the shared FPGA's frame identifier. It compares only actual decoded output with
the matching original source. It does not echo GUI input, regenerate a received
pattern, or run an alternative receiver that could hide failures of the working
output path. Reference-ring misses and late data receive no delivery credit.

A source block retires when source block n+2 begins. This allows one whole
following block for decoder latency. At retirement, expected, complete, good,
compared-bit and error-bit counters advance together for the same source cohort.
Partial blocks still contribute their actual compared bits and errors, but never
goodput. Duplicate IDs do not gain credit; misordered blocks are not complete.

Retirement continues when either/both optical links are blocked, provided TX is
still enabled and the selected mode is supported. The denominator is expected
source blocks, not just blocks that happened to arrive.

For differences between two coherent snapshots:

    Output BER = delta error bits / delta compared decoded output bits
    Goodput Mbps = delta good blocks * 256 / retired elapsed seconds / 1e6
    Delivery % = 100 * delta good blocks / delta expected retired blocks
    RX1/RX2 Mbps = delta checked line bits / wall elapsed seconds / 1e6

Both elapsed times come from the 250 MHz FPGA clock. Whole retired-block
boundaries avoid reporting greater than 100% simply because receiver latency
crossed a GUI polling boundary. These are interval measurements; cumulative raw
counters remain available in the audit log. All new totals are 64-bit and are
read from one frozen bank, not independent live high/low words.

The legacy BER1/BER2/ABER polling is unchanged. Its sampling boundaries can differ
slightly from the new snapshot interval; do not claim bit-for-bit identical time
windows between the legacy BER columns and the new output metrics.

Valid optical outage: goodput and delivery become zero; OBER is N/A if no output
bits were compared. Corrupted output can have nonzero OBER and lower goodput.
An initial baseline shows Measuring...; unsupported/invalid/stale telemetry shows
Unavailable. An unavailable measurement is not proof of an optical outage.

Startup or switching blocks that retire with missing decoded bytes remain
incomplete losses. The final not-yet-retired tail is excluded until its retirement.
Save a measurement while the run is active before Stop/reset clears the run.
Define experimental windows after the initial sweep; keep subsequent link
interruptions inside those windows.

## Reset, text and coding behavior

Start/restart, tuning, mode changes and reset start a fresh epoch and zero new
totals. Lock loss and DIV receiver selection do not zero them. R53 text requests
do not reset delivery metrics. R39 SMP text rearm does not reset these totals
either; if the existing pair engine drops data during its rearm, those are real
missing events and are retained in the measurements.

Using the manual board-test/blink switch invalidates delivery measurements until
a fresh Start/reset. This prevents reused source identifiers from crediting old
blocks. It does not change the existing manual optical test behavior.

The observer is passive: no signal from it drives the optical generator, decoder,
selector, pair engine or BER logic. Original SISO/DIV/SMP text protocols, optical
BER/ABER, clock, pins and RF policy are retained. Added logic can still affect
physical placement/timing, which must be checked by Quartus and on the bench.

The original modulation support gates still apply. DIV/SMP remain OOK-NRZ-only.
Coding overhead is measured through actual delivered source bytes; it is not
multiplied into goodput from a dropdown. CRC-8 checking is NOT added by this
version: correctness is determined against the known transmitted source. Do not
describe this as CRC-verified application delivery.

These are internal FPGA reconstructed optical payload measurements using shared
clock/frame-reference information, not an independent-clock network receiver or
continuous PC/USB file transfer. The GUI text box still shows a finite sample.

## RF backup

V3.2 RF arming/failover, default COM4 receiver and COM5 sender, configurable ports,
real RF received text and separate interval RF-BER are retained. No RF firmware
is changed. Keep using the matching continuous-v2 ESP32 pair.

While RF owns the displayed output, OBER, Throughput and Delivery show
Unavailable (RF). The new counters measure OPTICAL output only; optical audit
measurements continue in the log. RF packet BER is not interchangeable with
goodput/delivery of the fixed 32-byte optical blocks. No RF counts are inserted
into optical ABER, and no configured 1 Mbps value is passed off as RF goodput.

## Snapshot register extension

| ID | Meaning |
|---|---|
| 90 | Signature 0x4D333301 |
| 91 | Request a frozen measurement snapshot; returns request token |
| 92 | Completed snapshot token |
| 93 | Run epoch in bits31:2, mode in bits1:0 |
| 94 | Flags: enabled0, supported1, RX1lock2, RX2lock3, selectedRX2=4, warm5 |
| 95/96 | FPGA wall ticks, low/high |
| 97/98 | Retired expected blocks, low/high |
| 99/100 | Complete ordered blocks, low/high |
| 101/102 | Correct complete ordered blocks, low/high |
| 103/104 | Compared decoded payload bits, low/high |
| 105/106 | Decoded payload bit errors, low/high |
| 107/108 | RX1 checked line bits, low/high |
| 109/110 | RX2 checked line bits, low/high |
| 111 | Clock frequency: 250000000 Hz |
| 112 | Logical block length: 32 bytes |
| 113/114 | Last retirement timestamp, low/high |

C# checks signature, request/completion token, warmup, epoch/mode against the
existing optical poll, format constants, and final token/epoch stability.
It rejects inconsistent counts, implausible rates, stale/replayed snapshots and
long timing gaps. It does not require lock to calculate valid outage metrics.
New snapshot transfers have a two-second host-time freshness budget. A delayed
successful USB read is rejected and starts a fresh baseline; this guard cannot
cancel a blocked native synchronous FT601 call.

## Bench checklist

1. Keep V3.1/V3.2 backups. Build the C# and Quartus copies and review timing.
2. RF unticked: start DIV with None, OOK-NRZ and an identifiable pattern/text.
   Verify both receiver rates; block each lane separately, then both; recover.
3. Repeat in SMP. One blocked lane must stop complete source delivery even if
   the surviving lane has zero line BER. Preserve transients and lost cohorts.
4. Test 5, 10, 25 and 50 Mbps/link. Healthy uncoded ideal targets are R Mbps
   unique DIV output and 2R Mbps SMP output, NOT prefilled expectations.
5. Test a known corruption and verify OBER changes and affected blocks lose
   delivery credit. Repeat with coding when evaluating correction behavior.
6. Export the MIMO CSV and retain DELIVERY FSO audit lines with firmware version,
   epoch/token, raw counters and both timestamps. Record exact configuration,
   duration, repetitions and physical alignment/attenuation settings.
7. Separately test RF handover and return; optical-only output metrics must not
   masquerade as RF delivery. Check shared Stop/Reset/Close behavior.

Read VALIDATION.md for the precise test coverage and hardware limitations.
