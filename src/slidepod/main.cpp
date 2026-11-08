/*
 * SlidePod rev 0.1 — trombone slide position sensor
 *
 * Reads VL53L1X distance at 50 Hz, applies a Kalman filter, maps to
 * slide position (0.0–1.0), and broadcasts via BLE GATT notify.
 * Serial CSV output mirrors the BLE payload for debugging.
 *
 * BLE service: GATT notify, 6-byte payload (raw_mm + filt_mm + pos).
 * Advertises as "SlidePod". Connect with any BLE central (phone/laptop).
 *
 * Build targets:
 *   pio run -e slidepod-sim   Wokwi simulation (mock ToF, no BLE)
 *   pio run -e slidepod       Real hardware (VL53L1X + NimBLE)
 */

#include <Arduino.h>
#include <Wire.h>
#include "SimpleKalmanFilter.h"

// ── Sensor library — switched at compile time ────────────────────────────
#ifdef WOKWI_SIM
  // Wokwi ESP32 I2C is non-functional — mock the ToF with a triangle wave.
  static uint16_t mock_dist = 50;
  static int16_t  mock_step = 2;
  static bool     mock_sweep = true;
  static bool tof_init()  { return true; }
  static void tof_start() {}
  static uint16_t tof_read() {
    if (mock_sweep) {
      mock_dist += mock_step;
      if (mock_dist >= 550) { mock_dist = 550; mock_step = -2; }
      if (mock_dist <= 50)  { mock_dist = 50;  mock_step =  2; }
    }
    return mock_dist;
  }
  static bool tof_ok() { return true; }
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

// ── Pin assignments ──────────────────────────────────────────────────────
#ifdef WOKWI_SIM
  static constexpr int PIN_LED_R     = 25;
  static constexpr int PIN_LED_G     = 26;
  static constexpr int PIN_LED_B     = 27;
  static constexpr int PIN_BOOT      = 0;
#else
  // Real SlidePod hardware (ESP32-S3-MINI-1).
  static constexpr int PIN_SDA       = 8;
  static constexpr int PIN_SCL       = 9;
  static constexpr int PIN_TOF_XSHUT = 5;
  static constexpr int PIN_TOF_INT   = 4;
  static constexpr int PIN_LED_R     = 11;
  static constexpr int PIN_LED_G     = 12;
  static constexpr int PIN_LED_B     = 13;
  static constexpr int PIN_BOOT      = 0;
#endif

// ── BLE (real hardware only — Wokwi has no BLE stack) ───────────────────
#ifndef WOKWI_SIM
#include <NimBLEDevice.h>

#define SLIDEPOD_SVC_UUID  "d5e40001-7537-4463-a441-27f2d3140fab"
#define SLIDEPOD_POS_UUID  "d5e40002-7537-4463-a441-27f2d3140fab"

static NimBLECharacteristic* posChr = nullptr;

static void ble_init() {
  NimBLEDevice::init("SlidePod");

  auto* srv = NimBLEDevice::createServer();
  srv->advertiseOnDisconnect(true);

  auto* svc = srv->createService(SLIDEPOD_SVC_UUID);
  posChr = svc->createCharacteristic(
    SLIDEPOD_POS_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );
  svc->start();

  auto* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SLIDEPOD_SVC_UUID);
  adv->setScanResponse(true);
  adv->start();
}

// 6-byte LE payload: raw_mm(u16) + filt_mm(u16) + position(u16, 0–10000)
static void ble_notify(uint16_t raw, uint16_t filt, uint16_t pos10k) {
  if (!posChr || !posChr->getSubscribedCount()) return;
  uint8_t buf[6];
  buf[0] = raw;       buf[1] = raw >> 8;
  buf[2] = filt;      buf[3] = filt >> 8;
  buf[4] = pos10k;    buf[5] = pos10k >> 8;
  posChr->setValue(buf, sizeof(buf));
  posChr->notify();
}
#else
static void ble_init() {}
static void ble_notify(uint16_t, uint16_t, uint16_t) {}
#endif

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

  setRgb(true, false, false);   // red = booting

  Serial.println("# SlidePod booting...");

#ifndef WOKWI_SIM
  Wire.begin(PIN_SDA, PIN_SCL);
  // Power-cycle the ToF sensor via XSHUT.
  pinMode(PIN_TOF_XSHUT, OUTPUT);
  digitalWrite(PIN_TOF_XSHUT, LOW);
  delay(10);
  digitalWrite(PIN_TOF_XSHUT, HIGH);
  delay(10);
#endif

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

  ble_init();

  setRgb(false, true, false);   // green = ready
  Serial.println("# SlidePod ready");
  Serial.println("# dist_raw_mm,dist_filt_mm,position");
}

void loop() {
#ifdef WOKWI_SIM
  // BOOT button toggles between sweep and hold-at-closed.
  static bool prev_btn = LOW;
  bool btn = digitalRead(PIN_BOOT);
  if (prev_btn == HIGH && btn == LOW) {
    mock_sweep = !mock_sweep;
    if (!mock_sweep) mock_dist = 50;
  }
  prev_btn = btn;
#endif

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

  ble_notify(raw, (uint16_t)filt, (uint16_t)(pos * 10000.0f));

  Serial.print(raw);
  Serial.print(",");
  Serial.print(filt, 1);
  Serial.print(",");
  Serial.println(pos, 3);

  delay(20);  // 50 Hz
}
