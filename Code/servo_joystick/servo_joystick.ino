#include <Servo.h>

Servo sX;
Servo sY;

// Pins
const int PIN_SERVO_X = 9;
const int PIN_SERVO_Y = 10;

const int PIN_VRX = A0;
const int PIN_VRY = A1;

// Safer limits (adjust if needed)
const float ANGLE_MIN = 5;
const float ANGLE_MAX = 175;

// Joystick
int centerX = 512;
int centerY = 512;
const int deadzone = 90;

// EMA smoothing
float filtX = 512;
float filtY = 512;

// Movement tuning
const float MAX_STEP_PER_LOOP = 0.5f;

// Current angles
float angleX = 90.0f;
float angleY = 90.0f;

// ---------- helper: update one axis ----------
float updateAxis(int raw, int center, float &filt, float angle) {
  // Smooth input
  filt = 0.85f * filt + 0.15f * raw;
  int v = (int)filt;

  int delta = v - center;

  // Near centre -> STOP / hold
  if (abs(delta) <= deadzone) {
    return angle; // do nothing
  }

  // Step size proportional to how far you push
  int mag = abs(delta);
  mag = constrain(mag, deadzone, 512);

  float u = (float)(mag - deadzone) / (float)(512 - deadzone); // 0..1
  float step = u * MAX_STEP_PER_LOOP;

  // Direction
  if (delta > 0) angle += step;
  else           angle -= step;

  // Clamp
  if (angle < ANGLE_MIN) angle = ANGLE_MIN;
  if (angle > ANGLE_MAX) angle = ANGLE_MAX;

  return angle;
}

void setup() {
  Serial.begin(9600);

  sX.attach(PIN_SERVO_X);
  sY.attach(PIN_SERVO_Y);

  // ---- RESET BOTH SERVOS TO MIDDLE ON STARTUP ----
  angleX = 90.0f;
  angleY = 90.0f;
  sX.write((int)angleX);
  sY.write((int)angleY);
  delay(800); // give servos time to move to middle

  // ---- Calibrate centres (DON'T touch joystick during startup) ----
  long sumX = 0, sumY = 0;
  for (int i = 0; i < 200; i++) {
    sumX += analogRead(PIN_VRX);
    sumY += analogRead(PIN_VRY);
    delay(2);
  }
  centerX = sumX / 200;
  centerY = sumY / 200;

  // (Optional) Reset filters to the current readings to avoid a jump
  filtX = centerX;
  filtY = centerY;

  Serial.print("centerX = "); Serial.println(centerX);
  Serial.print("centerY = "); Serial.println(centerY);
}

void loop() {
  int rawX = analogRead(PIN_VRX);
  int rawY = analogRead(PIN_VRY);

  angleX = updateAxis(rawX, centerX, filtX, angleX);
  angleY = updateAxis(rawY, centerY, filtY, angleY);

  sX.write((int)angleX);
  sY.write((int)angleY);

  delay(10);
}
