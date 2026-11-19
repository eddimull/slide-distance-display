/*
 * SlidePod rev 0.1 — trombone slide position sensor
 *
 * Reads VL53L1X distance, maps it to a rough slide position (0.0–1.0) for
 * the LED, and broadcasts the raw reading via BLE GATT notify. Smoothing
 * (One-Euro filter) and calibrated position are done in the phone app.
 * A piezo contact pickup on the slide is sampled at 16 kHz (ADC DMA) and
 * run through YIN pitch detection every 20 ms.
 * Serial CSV output mirrors the BLE payload for debugging.
 *
 * BLE service: GATT notify, 8-byte payload (raw_mm + filt_mm + pos + pitch).
 * Advertises as "SlidePod". Connect with any BLE central (phone/laptop).
 *
 * Build targets:
 *   pio run -e slidepod-sim   Wokwi simulation (mock ToF, no BLE)
 *   pio run -e slidepod       Real hardware (VL53L1X + NimBLE)
 */

#include <Arduino.h>
#include <Wire.h>
#include "pitch_yin.h"

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
  // Real hardware: VL53L1X, switching mode with distance.
  //
  // Near (slide in, < 500 mm): Short mode, full 16x16 field of view, 15 ms
  // timing budget, 19 ms inter-measurement period -> a reading every
  // ~17.6 ms (the sensor's clock runs ~7.5% fast). The period needs ~4 ms
  // of headroom over the budget: with both at 20 ms it skipped every other
  // slot (37 ms), and 15/18 did the same at close range. Measured noise
  // ~2 mm mid-slide, ~11 mm at 1st.
  //
  // Far (past 500 mm): the slide crossbar is a weak return out there and
  // Short mode often loses it to the player's hand or the room. Medium mode
  // is more sensitive, and a 6x6 ROI (about half the field of view) keeps
  // more of the hand and room out. Medium needs a 33 ms budget; 37 ms
  // period skipped every other slot, 39 ms didn't; 41 ms -> ~26 readings/s.
  //
  // Medium read ~35 mm further than Short on the same crossbar at 5th, so
  // the switch points are kept apart (out at 500, back at 450) to stop the
  // mode flapping on that step.
  #include <VL53L1X.h>
  VL53L1X tof;
  static constexpr uint16_t TOF_FAR_ABOVE_MM = 500;
  static constexpr uint16_t TOF_NEAR_BELOW_MM = 450;
  static constexpr uint8_t TOF_ROI_CENTRE = 199;  // optical centre (col 8, row 8)
  static bool tof_far = false;
  static bool tof_valid = false;

  static bool tof_init() {
    tof.setTimeout(500);
    return tof.init();
  }
  static void tof_set_far(bool far) {
    tof.stopContinuous();
    if (far) {
      tof.setDistanceMode(VL53L1X::Medium);
      tof.setMeasurementTimingBudget(33000);
      tof.setROISize(6, 6);
      tof.setROICenter(TOF_ROI_CENTRE);
      tof.startContinuous(41);
    } else {
      tof.setDistanceMode(VL53L1X::Short);
      tof.setMeasurementTimingBudget(15000);
      tof.setROISize(16, 16);
      tof.setROICenter(TOF_ROI_CENTRE);
      tof.startContinuous(19);
    }
    tof_far = far;
    Serial.printf("# tof %s\n", far ? "far: Medium 6x6" : "near: Short 16x16");
  }
  static void tof_start() {
    tof_set_far(false);
  }
  static uint16_t tof_read() {
    const uint16_t mm = tof.read();
    tof_valid = tof.ranging_data.range_status == VL53L1X::RangeValid;
    // Switch on valid readings only; this one is still reported as is.
    if (tof_valid) {
      if (!tof_far && mm > TOF_FAR_ABOVE_MM) tof_set_far(true);
      else if (tof_far && mm < TOF_NEAR_BELOW_MM) tof_set_far(false);
    }
    return mm;
  }
  static bool tof_ok() {
    return tof_valid;
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
  // PIEZO_ADC is GPIO1 = ADC1_CH0 (hard-wired in the DMA config below).
#endif

// ── Piezo pitch detection ────────────────────────────────────────────────
// Written by the piezo task, read by loop(). 32-bit aligned floats are
// atomic on Xtensa, so no lock needed for a single latest value.
static volatile float g_pitchHz  = 0;   // 0 = no clear pitch
static volatile float g_piezoRms = 0;   // ADC counts, for tuning amp gain

// Off by default: rev 0.1 boards have no piezo fitted. Build with
// -D SLIDEPOD_PIEZO to turn it back on. The 57 Hz loop / 7.5 ms BLE
// timing was verified with it off; re-check that if you enable it.
#if !defined(WOKWI_SIM) && defined(SLIDEPOD_PIEZO)
#include <driver/adc.h>

static PitchYin yin;  // ~7 KB of buffers; global, not on the task stack

static void piezo_task(void*) {
  adc_digi_init_config_t init = {};
  init.max_store_buf_size = 4096;   // ~64 ms of slack at 16 kHz
  init.conv_num_each_intr = 256;    // bytes per DMA interrupt (64 samples)
  init.adc1_chan_mask     = BIT(0); // ADC1_CH0 = GPIO1
  init.adc2_chan_mask     = 0;

  adc_digi_pattern_config_t pat = {};
  pat.atten     = ADC_ATTEN_DB_11;  // ~0–3.1 V, amp output is mid-rail biased
  pat.channel   = ADC1_CHANNEL_0;
  pat.unit      = 0;                // ADC1
  pat.bit_width = SOC_ADC_DIGI_MAX_BITWIDTH;

  adc_digi_configuration_t cfg = {};
  cfg.conv_limit_en  = false;
  cfg.conv_limit_num = 250;
  cfg.pattern_num    = 1;
  cfg.adc_pattern    = &pat;
  cfg.sample_freq_hz = (uint32_t)PitchYin::kSampleRate;
  cfg.conv_mode      = ADC_CONV_SINGLE_UNIT_1;
  cfg.format         = ADC_DIGI_OUTPUT_FORMAT_TYPE2;

  esp_err_t err = adc_digi_initialize(&init);
  if (err == ESP_OK) err = adc_digi_controller_configure(&cfg);
  if (err == ESP_OK) err = adc_digi_start();
  if (err != ESP_OK) {
    Serial.printf("# ERROR: piezo ADC DMA init failed (%d)\n", err);
    vTaskDelete(nullptr);
    return;
  }

  static constexpr int kHop = (int)(PitchYin::kSampleRate / 50);  // 20 ms
  uint8_t buf[256];
  int sinceHop = 0;
  for (;;) {
    uint32_t n = 0;
    err = adc_digi_read_bytes(buf, sizeof(buf), &n, 100);
    // INVALID_STATE = driver buffer overflowed (we fell behind); the bytes
    // returned are still good, so keep going.
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) continue;
    for (uint32_t i = 0; i + sizeof(adc_digi_output_data_t) <= n;
         i += sizeof(adc_digi_output_data_t)) {
      const auto* d = reinterpret_cast<const adc_digi_output_data_t*>(&buf[i]);
      if (d->type2.unit != 0 || d->type2.channel != 0) continue;
      yin.push((float)d->type2.data);
      if (++sinceHop >= kHop) {
        sinceHop = 0;
        g_pitchHz  = yin.detect();
        g_piezoRms = yin.rms();
      }
    }
  }
}

static void piezo_init() {
  // Core 1 alongside loop(), higher priority so sampling never starves;
  // a detect() pass is ~2 ms per 20 ms hop. NimBLE's host runs on core 0.
  xTaskCreatePinnedToCore(piezo_task, "piezo", 4096, nullptr, 2, nullptr, 1);
}
#else
static void piezo_init() {}  // disabled or Wokwi: pitch stays 0
#endif

// ── BLE (real hardware only — Wokwi has no BLE stack) ───────────────────
// LED colour from the app (see LedWrite). Written from the BLE task.
static volatile bool g_ledFromApp = false;
static volatile uint8_t g_ledR = 0, g_ledG = 0, g_ledB = 0;

#ifndef WOKWI_SIM
#include <NimBLEDevice.h>

#define SLIDEPOD_SVC_UUID  "d5e40001-7537-4463-a441-27f2d3140fab"
#define SLIDEPOD_POS_UUID  "d5e40002-7537-4463-a441-27f2d3140fab"
#define SLIDEPOD_LED_UUID  "d5e40003-7537-4463-a441-27f2d3140fab"

static NimBLECharacteristic* posChr = nullptr;

// LED colour set by the app (Easy mode colour-codes positions; only the app
// knows the calibrated position). Write [1, r, g, b] to hold a colour,
// [0] to hand the LED back to the pod.
class LedWrite : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    const std::string v = c->getValue();
    if (v.size() >= 4 && v[0] == 1) {
      g_ledR = v[1]; g_ledG = v[2]; g_ledB = v[3];
      g_ledFromApp = true;
    } else {
      g_ledFromApp = false;
    }
  }
};
static LedWrite ledWriteCb;

// Debug: log raw GAP connect/disconnect events (status / reason codes).
static int gap_log(struct ble_gap_event* ev, void*) {
  switch (ev->type) {
    case BLE_GAP_EVENT_CONNECT:
      Serial.printf("# BLE connect status=%d handle=%d\n",
                    ev->connect.status, ev->connect.conn_handle);
      break;
    case BLE_GAP_EVENT_DISCONNECT:
      Serial.printf("# BLE disconnect reason=0x%03x\n", ev->disconnect.reason);
      break;
    case BLE_GAP_EVENT_CONN_UPDATE:
      Serial.printf("# BLE conn update status=%d\n", ev->conn_update.status);
      break;
    case BLE_GAP_EVENT_SUBSCRIBE:
      Serial.printf("# BLE subscribe notify=%d\n", ev->subscribe.cur_notify);
      break;
  }
  return 0;
}

// Ask for the fastest BLE connection interval (7.5 ms) once the phone
// subscribes. Android otherwise settles on 45 ms ("balanced") right after
// service discovery, which adds up to 45 ms (avg ~22 ms) before each
// notify goes out. Requesting at subscribe time lands after Android's own
// update, so it isn't overridden. (iOS rejects < 15 ms and keeps its own.)
class FastConnOnSubscribe : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic*, ble_gap_conn_desc* desc,
                   uint16_t subValue) override {
    if (!subValue) return;
    // Units: interval 1.25 ms (6 = 7.5 ms), timeout 10 ms (200 = 2 s).
    NimBLEDevice::getServer()->updateConnParams(desc->conn_handle, 6, 6, 0, 200);
  }
};
static FastConnOnSubscribe fastConnCb;

// The subscribe-time request can collide with Android's own switch to
// 45 ms (pod sees LL Procedure Collision, 0x223) and NimBLE won't retry.
// So re-check and re-request while the interval is still above 7.5 ms.
// Retry slowly: an accepted update takes ~360 ms to apply, and asking again
// sooner cancels it (0x23B). Measured on the phone: Android accepts 7.5 ms
// every time it gets the request cleanly. iOS will keep refusing (< 15 ms).
static void ble_keep_fast() {
  static uint32_t lastCheck = 0;
  static uint8_t tries = 0;
  if (millis() - lastCheck < 1500) return;
  lastCheck = millis();
  auto* srv = NimBLEDevice::getServer();
  // Handles get reused across connections, so reset whenever nobody's on.
  if (!srv || !srv->getConnectedCount()) {
    tries = 0;
    g_ledFromApp = false;  // app gone: the pod owns the LED again
    return;
  }
  if (!posChr->getSubscribedCount()) return;
  NimBLEConnInfo info = srv->getPeerInfo(0);
  if (info.getConnInterval() <= 6 || tries >= 5) return;
  tries++;
  srv->updateConnParams(info.getConnHandle(), 6, 6, 0, 200);
}

static void ble_init() {
  NimBLEDevice::init("SlidePod");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setCustomGapHandler(gap_log);

  auto* srv = NimBLEDevice::createServer();
  srv->advertiseOnDisconnect(true);

  auto* svc = srv->createService(SLIDEPOD_SVC_UUID);
  posChr = svc->createCharacteristic(
    SLIDEPOD_POS_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );
  posChr->setCallbacks(&fastConnCb);
  svc->createCharacteristic(
    SLIDEPOD_LED_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  )->setCallbacks(&ledWriteCb);
  svc->start();

  auto* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SLIDEPOD_SVC_UUID);
  adv->setScanResponse(true);
  adv->start();
}

// 8-byte LE payload: raw_mm(u16) + filt_mm(u16) + position(u16, 0–10000)
//   filt_mm now repeats raw_mm (filtering moved to the app); the slot is
//   kept so older app builds still parse the packet.
//                    + pitch(u16, 0.1 Hz units, 0 = none)
static void ble_notify(uint16_t raw, uint16_t filt, uint16_t pos10k,
                       uint16_t pitch10) {
  if (!posChr || !posChr->getSubscribedCount()) return;
  uint8_t buf[8];
  buf[0] = raw;       buf[1] = raw >> 8;
  buf[2] = filt;      buf[3] = filt >> 8;
  buf[4] = pos10k;    buf[5] = pos10k >> 8;
  buf[6] = pitch10;   buf[7] = pitch10 >> 8;
  posChr->setValue(buf, sizeof(buf));
  posChr->notify();
}
#else
static void ble_init() {}
static void ble_keep_fast() {}
static void ble_notify(uint16_t, uint16_t, uint16_t, uint16_t) {}
#endif

// ── Slide geometry (mm) — calibrate with cal_offset / cal_len over BLE ──
static constexpr float DIST_CLOSED = 50.0f;    // ToF reading at position 0
static constexpr float DIST_OPEN   = 550.0f;   // ToF reading at position 7


static void setRgb8(uint8_t r, uint8_t g, uint8_t b) {
  // Only touch the PWM when the colour changes.
  static int last = -1;
  const int key = (r << 16) | (g << 8) | b;
  if (key == last) return;
  last = key;
  // Active-low: 255 - level (255 = steady high = off).
  analogWrite(PIN_LED_R, 255 - r);
  analogWrite(PIN_LED_G, 255 - g);
  analogWrite(PIN_LED_B, 255 - b);
}

static void setRgb(bool r, bool g, bool b) {
  setRgb8(r ? 255 : 0, g ? 255 : 0, b ? 255 : 0);
}

void setup() {
  Serial.begin(115200);
#if ARDUINO_USB_CDC_ON_BOOT && ARDUINO_USB_MODE
  // USB-Serial-JTAG: once a host has enumerated us, the core waits up to
  // 100 ms per write when nobody is reading the port. With the cable in a
  // PC but no monitor open, that stalled loop() to ~1 update / 1.6 s.
  // Never block: drop serial output instead.
  Serial.setTxTimeoutMs(0);
#endif

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

  piezo_init();
  ble_init();

  setRgb(false, true, false);   // green = ready
  Serial.println("# SlidePod ready");
  Serial.println("# dist_raw_mm,position,pitch_hz,piezo_rms");
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

  ble_keep_fast();

  uint16_t raw = tof_read();
  if (!tof_ok()) {
    Serial.println("# timeout");
    return;
  }

  float pos  = constrain(
    ((float)raw - DIST_CLOSED) / (DIST_OPEN - DIST_CLOSED),
    0.0f, 1.0f);

  // LED: the app's colour if it set one (Easy mode), otherwise green at
  // rest and blue when the slide is out.
  if (g_ledFromApp)
    setRgb8(g_ledR, g_ledG, g_ledB);
  else if (pos > 0.03f)
    setRgb(false, false, true);
  else
    setRgb(false, true, false);

  const float pitch = g_pitchHz;
  ble_notify(raw, raw, (uint16_t)(pos * 10000.0f),
             (uint16_t)(pitch * 10.0f + 0.5f));

  Serial.print(raw);
  Serial.print(",");
  Serial.print(pos, 3);
  Serial.print(",");
  Serial.print(pitch, 1);
  Serial.print(",");
  Serial.println(g_piezoRms, 1);

#ifdef WOKWI_SIM
  delay(18);  // mock sensor returns instantly; pace it like the real one
#endif
  // Real hardware: no delay. tof_read() blocks until the sensor's next
  // reading, so the loop runs at the sensor's rate.
}
