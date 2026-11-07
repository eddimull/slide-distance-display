/*
 * SlidePod rev 0.1 — firmware skeleton
 *
 * Reads VL53L1X distance at 50 Hz, applies a Kalman filter, maps it to a
 * trombone slide position (0.0–1.0), and outputs CSV on Serial (mirroring
 * what the BLE GATT notify will send once NimBLE is wired in).
 *
 * Build targets:
 *   pio run -e slidepod-sim   Wokwi simulation (uses VL53L0X proxy)
 *   pio run -e slidepod       Real SlidePod hardware (uses VL53L1X)
 *
 * In Wokwi: use the serial plotter (bottom panel) to watch dist_raw,
 * dist_filt, and position in real time. Drag the VL53L0X distance slider
 * to simulate slide movement.
 */

#include <Arduino.h>
#include <Wire.h>
#include "SimpleKalmanFilter.h"

// ── Sensor library — switched at compile time ────────────────────────────
#ifdef WOKWI_SIM
  // Wokwi only ships a wokwi-vl53l0x device; use the VL53L0X lib as proxy.
  #include <VL53L0X.h>
  VL53L0X tof;
  static bool tof_init() {
    tof.setTimeout(500);
    return tof.init();
  }
  static void tof_start() {
    tof.setMeasurementTimingBudget(20000);
    tof.startContinuous();
  }
  static uint16_t tof_read() {
    return tof.readRangeContinuousMillimeters();
  }
  static bool tof_ok() {
    return !tof.timeoutOccurred();
  }
#else
  // Real hardware: VL53L1X in Short mode, 20 ms timing budget.
  #include <VL53L1X.h>
  VL53L1X tof;
  static bool tof_init() {
    tof.setTimeout(500);
    return tof.init();
  }
  static void tof_start() {
    tof.setDistanceMode(VL53L1X::Short);
    tof.setMeasurementTimingBudget(20000);
    tof.startContinuous(20);
  }
  static uint16_t tof_read() {
    return tof.read();
  }
  static bool tof_ok() {
    return tof.ranging_data.range_status == VL53L1X::RangeValid;
  }
#endif

// ── Pin assignments (from hardware/README.md) ────────────────────────────
static constexpr int PIN_SDA       = 8;
static constexpr int PIN_SCL       = 9;
static constexpr int PIN_TOF_XSHUT = 5;
static constexpr int PIN_TOF_INT   = 4;
static constexpr int PIN_LED_R     = 11;   // active-low: anode → 3V3
static constexpr int PIN_LED_G     = 12;
static constexpr int PIN_LED_B     = 13;
static constexpr int PIN_BOOT      = 0;

// ── Slide geometry (mm) — calibrate with cal_offset / cal_len over BLE ──
static constexpr float DIST_CLOSED = 50.0f;    // ToF reading at position 0
static constexpr float DIST_OPEN   = 550.0f;   // ToF reading at position 7

// ── Kalman filter (mea_e, est_e, q) — tune q for responsiveness ─────────
SimpleKalmanFilter kalman(2.0f, 2.0f, 0.01f);

static void setRgb(bool r, bool g, bool b) {
  // Active-low: drive LOW to light the LED.
  digitalWrite(PIN_LED_R, r ? LOW : HIGH);
  digitalWrite(PIN_LED_G, g ? LOW : HIGH);
  digitalWrite(PIN_LED_B, b ? LOW : HIGH);
}

void setup() {
  Serial.begin(115200);

  pinMode(PIN_LED_R, OUTPUT);
  pinMode(PIN_LED_G, OUTPUT);
  pinMode(PIN_LED_B, OUTPUT);
  pinMode(PIN_BOOT, INPUT_PULLUP);
  pinMode(PIN_TOF_XSHUT, OUTPUT);

  setRgb(true, false, false);   // red = booting

  Wire.begin(PIN_SDA, PIN_SCL);

  // Power-cycle the ToF sensor via XSHUT.
  digitalWrite(PIN_TOF_XSHUT, LOW);
  delay(10);
  digitalWrite(PIN_TOF_XSHUT, HIGH);
  delay(10);

  if (!tof_init()) {
    Serial.println("# ERROR: VL53L sensor not found");
    while (1) {
      setRgb(true, false, false);
      delay(200);
      setRgb(false, false, false);
      delay(200);
    }
  }

  tof_start();

  setRgb(false, true, false);   // green = ready
  Serial.println("# SlidePod ready");
  Serial.println("# dist_raw_mm,dist_filt_mm,position");
}

void loop() {
  uint16_t raw = tof_read();
  if (!tof_ok()) {
    Serial.println("# timeout");
    return;
  }

  float filt = kalman.updateEstimate((float)raw);
  float pos  = constrain(
    (filt - DIST_CLOSED) / (DIST_OPEN - DIST_CLOSED),
    0.0f, 1.0f);

  // LED: green at rest, blue when slide is out.
  if (pos > 0.03f)
    setRgb(false, false, true);
  else
    setRgb(false, true, false);

  // CSV output — mirrors the payload that BLE GATT notify will send.
  // Format: raw_mm, filtered_mm, position (0.000–1.000)
  Serial.print(raw);
  Serial.print(",");
  Serial.print(filt, 1);
  Serial.print(",");
  Serial.println(pos, 3);

  delay(20);  // 50 Hz
}
