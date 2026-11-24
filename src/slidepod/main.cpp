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
 * Each pod has a serial (its chip's factory MAC, 12 hex digits) and a name,
 * "SlidePod" plus the serial's last 4 digits until the app renames it. It
 * advertises the name, the service and the serial (manufacturer data), so
 * the app can tell pods apart before connecting. See ble_init().
 *
 * Build targets:
 *   pio run -e slidepod-sim   Wokwi simulation (mock ToF, no BLE)
 *   pio run -e slidepod-wokwi Wokwi rev 0.2 board sim: real ToF driver against an
 *                             emulated VL53L1X (sim/wokwi-rev2), no BLE
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
  static unsigned tof_status_code() { return 0; }
  static const char *tof_mode_name() { return "sim"; }
#else
  // Real hardware: VL53L1X, switching mode with distance.
  //
  // Near (slide in, < 500 mm): Short mode, 4x8 ROI, 15 ms
  // timing budget, 19 ms inter-measurement period -> a reading every
  // ~17.6 ms (the sensor's clock runs ~7.5% fast). The period needs ~4 ms
  // of headroom over the budget: with both at 20 ms it skipped every other
  // slot (37 ms), and 15/18 did the same at close range. Measured noise
  // with the old 16x16 view: ~2 mm mid-slide, ~11 mm at 1st (4x8: 0-2 mm
  // held in 1st).
  //
  // The ROI is 4 wide x 8 tall (of 16x16 SPADs) so the sensor sees only
  // the narrow slide brace. With the full 16x16 view it saw a second
  // surface too and flipped between the two every other reading (194/232
  // mm held still at 3rd, 0/15 mm in 1st; 2026-11-20). Held still at 3rd:
  // 4x4-4x10 all steady (sd ~1.8 mm); from 4x12 up the second surface
  // creeps back in. 4x8 tracked a full 1st-7th gliss with no flipping.
  //
  // Far (past 500 mm): the slide crossbar is a weak return out there and
  // Short mode often loses it to the player's hand or the room. Medium mode
  // is more sensitive, and a 6x6 ROI (about half the field of view) keeps
  // more of the hand and room out. Medium needs a 33 ms budget; 37 ms
  // period skipped every other slot, 39 ms didn't; 41 ms -> ~26 readings/s.
  //
  // With the old 16x16 near view Medium read ~35 mm further than Short at
  // 5th (likely the second surface, see above). With 4x8 the readings run
  // straight across every switch, out and back, no step beyond the motion
  // (slow passes, 2026-11-20). The switch points stay apart (out at 500,
  // back at 450) so noise at the boundary can't make the modes flap.
  #include <VL53L1X.h>
  VL53L1X tof;
  static constexpr uint16_t TOF_FAR_ABOVE_MM = 500;
  static constexpr uint16_t TOF_NEAR_BELOW_MM = 450;
  static constexpr uint8_t TOF_ROI_CENTRE = 199;  // optical centre (col 8, row 8)
  static bool tof_far = false;
  static bool tof_valid = false;
  static uint8_t tof_status = 0;   // last VL53L1X::RangeStatus
  static uint8_t tof_misses = 0;   // invalid readings in a row

  // The switch back to near used to need a valid reading under 450 mm, but
  // with the slide closed Medium can fail every reading, so the pod stuck in
  // far mode reporting nothing (45 s with the slide in 1st, 2026-11-20).
  // After this many misses in a row in far mode (~330 ms), go back to
  // near. Only that way: near rarely fails, and swapping on its misses too
  // made the modes flap every ~0.5 s around 6th-7th (2026-11-20 capture).
  static constexpr uint8_t TOF_MISSES_TO_NEAR = 8;

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
      tof.setROISize(4, 8);
      tof.setROICenter(TOF_ROI_CENTRE);
      tof.startContinuous(19);
    }
    tof_far = far;
    tof_misses = 0;
    Serial.printf("# tof %s\n", far ? "far: Medium 6x6" : "near: Short 4x8");
  }
  static void tof_start() {
    tof_set_far(false);
  }
  static uint16_t tof_read() {
    const uint16_t mm = tof.read();
    tof_status = tof.ranging_data.range_status;
    tof_valid = tof_status == VL53L1X::RangeValid;
    // Switch on valid readings; this one is still reported as is.
    if (tof_valid) {
      tof_misses = 0;
      if (!tof_far && mm > TOF_FAR_ABOVE_MM) tof_set_far(true);
      else if (tof_far && mm < TOF_NEAR_BELOW_MM) tof_set_far(false);
    } else if (tof_far && ++tof_misses >= TOF_MISSES_TO_NEAR) {
      tof_misses = 0;
      tof_set_far(false);
    }
    return mm;
  }
  static bool tof_ok() {
    return tof_valid;
  }
  static unsigned tof_status_code() { return tof_status; }
  static const char *tof_mode_name() { return tof_far ? "far" : "near"; }
#endif

// raw_mm sent when the ToF had no valid reading.
static constexpr uint16_t TOF_NO_READING = 0xFFFF;

// ── Pin assignments ──────────────────────────────────────────────────────
#ifdef WOKWI_SIM
  static constexpr int PIN_LED_R     = 25;
  static constexpr int PIN_LED_G     = 26;
  static constexpr int PIN_LED_B     = 27;
  static constexpr int PIN_BOOT      = 0;
#else
  // Real SlidePod hardware (ESP32-S3-MINI-1). Build with -DSLIDEPOD_REV=2 for rev 0.2 boards.
  #ifndef SLIDEPOD_REV
    #define SLIDEPOD_REV 1
  #endif
  #if SLIDEPOD_REV >= 2
  // rev 0.2 (32 x 26 mm): everything on the module's right edge; LSM6DS3TR-C IMU added.
  // NOTE: these pins were reassigned during PCB layout so the traces could be routed (the
  // order along the module edge follows the parts on the board). They are NOT the earlier
  // rev 0.2 draft map (SDA 37 / SCL 36 / XSHUT 42 / INT 41 / LEDs 40-38 / IMU_INT 35).
  // The source of truth is the `esp` pin map in hardware/tools/circuit.py; keep them in sync.
  // The ToF and the IMU are on separate I2C buses: ToF on Wire (PIN_SDA/PIN_SCL),
  // IMU on Wire1 (PIN_IMU_SDA/PIN_IMU_SCL), each with its own 4.7k pull-ups on the board.
  static constexpr int PIN_LED_R     = 42;
  static constexpr int PIN_LED_G     = 41;
  static constexpr int PIN_LED_B     = 40;
  static constexpr int PIN_SCL       = 39;   // ToF (VL53L1X, 0x29) bus
  static constexpr int PIN_SDA       = 38;
  static constexpr int PIN_TOF_INT   = 37;
  static constexpr int PIN_TOF_XSHUT = 36;
  static constexpr int PIN_IMU_SCL   = 35;   // IMU (LSM6DS3TR-C, 0x6A) bus -> Wire1
  static constexpr int PIN_IMU_SDA   = 48;
  static constexpr int PIN_IMU_INT   = 34;   // LSM6DS3TR-C INT1
  #else
  // rev 0.1
  static constexpr int PIN_SDA       = 8;
  static constexpr int PIN_SCL       = 9;
  static constexpr int PIN_TOF_XSHUT = 5;
  static constexpr int PIN_TOF_INT   = 4;
  static constexpr int PIN_LED_R     = 11;
  static constexpr int PIN_LED_G     = 12;
  static constexpr int PIN_LED_B     = 13;
  #endif
  static constexpr int PIN_BOOT      = 0;
  // PIEZO_ADC is GPIO1 = ADC1_CH0 (hard-wired in the DMA config below).
  // Same on rev 0.1 and 0.2 (module pins 6 and 14, hardware/tools/circuit.py).
  static constexpr int PIN_VBAT_SENSE = 2;   // ADC1_CH1, VBAT through 1M/1M
  static constexpr int PIN_VBUS_SENSE = 10;  // VBUS through 100k/100k: USB present
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

// SLIDEPOD_NO_BLE: real-hardware build without BLE, for the Wokwi rev 0.2 sim
// (env slidepod-wokwi). Wokwi doesn't simulate the ESP32-S3's Bluetooth.
#if !defined(WOKWI_SIM) && !defined(SLIDEPOD_NO_BLE)
#include <NimBLEDevice.h>

#define SLIDEPOD_SVC_UUID  "d5e40001-7537-4463-a441-27f2d3140fab"
#define SLIDEPOD_POS_UUID  "d5e40002-7537-4463-a441-27f2d3140fab"
#define SLIDEPOD_LED_UUID  "d5e40003-7537-4463-a441-27f2d3140fab"
#define SLIDEPOD_NAME_UUID "d5e40004-7537-4463-a441-27f2d3140fab"
#define SLIDEPOD_INFO_UUID "d5e40005-7537-4463-a441-27f2d3140fab"
#define SLIDEPOD_POWER_UUID "d5e40006-7537-4463-a441-27f2d3140fab"

// Firmware version, reported in the info characteristic.
#define SLIDEPOD_FW "0.4.0"

// Longest name, in UTF-8 bytes: fits the scan response (31 bytes) with room
// to spare, and the app's lists.
static constexpr size_t POD_NAME_MAX = 20;

#include <Preferences.h>

static char g_serial[13];          // e.g. "7CDFA1E23F2A"
static std::string g_name;          // what the pod advertises

// The chip's factory (base) MAC, as 12 hex digits. The BLE address is
// derived from it, but the base MAC is what's printed for the chip and
// doesn't change if the BLE address type does.
static void load_serial() {
  const uint64_t mac = ESP.getEfuseMac();  // byte 0 of the MAC is the low byte
  snprintf(g_serial, sizeof g_serial, "%02X%02X%02X%02X%02X%02X",
           (unsigned)(mac & 0xFF), (unsigned)((mac >> 8) & 0xFF),
           (unsigned)((mac >> 16) & 0xFF), (unsigned)((mac >> 24) & 0xFF),
           (unsigned)((mac >> 32) & 0xFF), (unsigned)((mac >> 40) & 0xFF));
}

static std::string default_name() {
  return std::string("SlidePod ") + (g_serial + 8);
}

// A name is 1–POD_NAME_MAX bytes of valid UTF-8 with no control characters,
// and not just spaces.
static bool valid_name(const std::string& n) {
  if (n.empty() || n.size() > POD_NAME_MAX) return false;
  bool visible = false;
  for (size_t i = 0; i < n.size();) {
    const uint8_t c = n[i];
    size_t len = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3
               : (c >> 3) == 0x1E ? 4 : 0;
    if (!len || i + len > n.size()) return false;
    for (size_t k = 1; k < len; k++)
      if ((uint8_t(n[i + k]) >> 6) != 0x2) return false;
    if (len == 1 && (c < 0x20 || c == 0x7F)) return false;
    if (c != ' ') visible = true;
    i += len;
  }
  return visible;
}

static void load_name() {
  Preferences prefs;
  prefs.begin("slidepod", true);
  const String saved = prefs.getString("name", "");
  prefs.end();
  g_name = saved.length() ? std::string(saved.c_str()) : default_name();
  if (!valid_name(g_name)) g_name = default_name();
}

static NimBLECharacteristic* posChr = nullptr;
static NimBLECharacteristic* powerChr = nullptr;

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

// The pod's name. Write 1–20 bytes of UTF-8 to rename it, or nothing (an
// empty write) to go back to the default. Saved in flash; advertised from
// the next disconnect (the pod doesn't advertise while connected).
class NameWrite : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    std::string v = c->getValue();
    if (v.empty()) {
      v = default_name();
    } else if (!valid_name(v)) {
      c->setValue(g_name);  // refuse: keep reading back the current name
      return;
    }
    Preferences prefs;
    prefs.begin("slidepod", false);
    if (v == default_name()) prefs.remove("name");
    else prefs.putString("name", v.c_str());
    prefs.end();
    g_name = v;
    c->setValue(g_name);
    NimBLEDevice::setDeviceName(g_name);  // the GAP name, read after connecting
    NimBLEDevice::getAdvertising()->setName(g_name);
    Serial.printf("# renamed: %s\n", g_name.c_str());
  }
};
static NameWrite nameWriteCb;

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
  load_serial();
  load_name();
  NimBLEDevice::init(g_name);
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
  auto* nameChr = svc->createCharacteristic(
    SLIDEPOD_NAME_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE
  );
  nameChr->setValue(g_name);
  nameChr->setCallbacks(&nameWriteCb);
  // Who this pod is, as JSON. A custom characteristic rather than Device
  // Information's serial number, which Web Bluetooth blocks.
  char info[96];
  snprintf(info, sizeof info, "{\"serial\":\"%s\",\"fw\":\"%s\",\"hw\":%d}",
           g_serial, SLIDEPOD_FW, SLIDEPOD_REV);
  svc->createCharacteristic(SLIDEPOD_INFO_UUID, NIMBLE_PROPERTY::READ)
     ->setValue(std::string(info));
  // Battery: see battery_update().
  powerChr = svc->createCharacteristic(
    SLIDEPOD_POWER_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );
  svc->start();

  // Advertisement (31 bytes): flags (3) + the service UUID (18) + the serial
  // as manufacturer data (10: company 0xFFFF, the "no company" test ID, then
  // the 6 MAC bytes). The name doesn't fit, so NimBLE puts it in the scan
  // response.
  uint8_t mfg[8] = {0xFF, 0xFF};
  const uint64_t mac = ESP.getEfuseMac();
  for (int i = 0; i < 6; i++) mfg[2 + i] = (mac >> (8 * i)) & 0xFF;
  auto* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SLIDEPOD_SVC_UUID);
  adv->setManufacturerData(std::string((const char*)mfg, sizeof mfg));
  adv->setScanResponse(true);
  adv->setName(g_name);
  adv->start();
  Serial.printf("# %s, serial %s, firmware %s\n", g_name.c_str(), g_serial,
                SLIDEPOD_FW);
}

// 8-byte LE payload: raw_mm(u16) + filt_mm(u16) + position(u16, 0–10000)
//   raw_mm = filt_mm = 0xFFFF: no ToF reading this cycle.
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

// ── Battery ─────────────────────────────────────────────────────────────
// 1S LiPo, read through a 1M/1M divider every 2 s and smoothed. The charge
// level comes from the resting-voltage curve, so on USB (charging, or no
// battery fitted) it reads high: the app shows "charging" then.
static constexpr uint8_t BATTERY_UNKNOWN = 0xFF;
static uint8_t g_batteryPct = BATTERY_UNKNOWN;
static uint16_t g_batteryMv = 0;
static bool g_usbPower = false;

// Percent for a resting cell voltage (mV), from a typical LiPo curve.
static uint8_t lipo_percent(float mv) {
  static const float curve[][2] = {
    {3300, 0}, {3500, 5}, {3600, 10}, {3700, 25}, {3750, 35}, {3800, 45},
    {3850, 55}, {3900, 63}, {4000, 78}, {4100, 90}, {4200, 100},
  };
  constexpr int n = sizeof curve / sizeof curve[0];
  if (mv <= curve[0][0]) return 0;
  if (mv >= curve[n - 1][0]) return 100;
  for (int i = 1; i < n; i++) {
    if (mv <= curve[i][0]) {
      const float t = (mv - curve[i - 1][0]) / (curve[i][0] - curve[i - 1][0]);
      return (uint8_t)(curve[i - 1][1] + t * (curve[i][1] - curve[i - 1][1]) + 0.5f);
    }
  }
  return 100;
}

#if !defined(WOKWI_SIM)
// Returns true when the reading changed enough to tell the app.
static bool battery_update() {
  static uint32_t last = 0;
  static float smooth = 0;
  if (last && millis() - last < 2000) return false;
  last = millis();
  uint32_t sum = 0;
  for (int i = 0; i < 16; i++) sum += analogReadMilliVolts(PIN_VBAT_SENSE);
  const float mv = 2.0f * sum / 16;  // undo the 1M/1M divider
  smooth = smooth == 0 ? mv : smooth + 0.2f * (mv - smooth);
  const bool usb = analogReadMilliVolts(PIN_VBUS_SENSE) > 1500;  // 2.5 V on USB
  // Below 2.5 V there's no cell (or a dead one behind its protection).
  const uint8_t pct = smooth < 2500 ? BATTERY_UNKNOWN : lipo_percent(smooth);
  const bool changed = pct != g_batteryPct || usb != g_usbPower;
  g_batteryPct = pct;
  g_batteryMv = (uint16_t)smooth;
  g_usbPower = usb;
  return changed;
}
#else
static bool battery_update() { return false; }
#endif

#if !defined(WOKWI_SIM) && !defined(SLIDEPOD_NO_BLE)
// 4 bytes: percent (0–100, 0xFF = unknown), flags (bit 0: on USB power),
// battery mV (u16 LE).
static void ble_power(bool notify) {
  if (!powerChr) return;
  const uint8_t v[4] = {g_batteryPct, (uint8_t)(g_usbPower ? 1 : 0),
                        (uint8_t)g_batteryMv, (uint8_t)(g_batteryMv >> 8)};
  powerChr->setValue(v, sizeof v);
  if (notify && powerChr->getSubscribedCount()) powerChr->notify();
}
#else
static void ble_power(bool) {}
#endif

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
  battery_update();
  ble_power(false);
  Serial.printf("# battery %u mV, %u%%, usb=%d\n", g_batteryMv, g_batteryPct, g_usbPower);

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
  if (battery_update()) {
    ble_power(true);
    Serial.printf("# battery %u mV, %u%%, usb=%d\n", g_batteryMv, g_batteryPct, g_usbPower);
  }

  uint16_t raw = tof_read();
  if (!tof_ok()) {
    // No valid reading (often far out in Medium mode, where the crossbar
    // is a weak return). Still tell the app, with raw_mm = 0xFFFF, so it
    // keeps updating (it places the slide from the pitch meanwhile)
    // instead of freezing until the sensor sees the slide again.
    ble_notify(TOF_NO_READING, TOF_NO_READING, 0,
               (uint16_t)(g_pitchHz * 10.0f + 0.5f));
    Serial.printf("# no reading status=%u mode=%s\n", tof_status_code(),
                  tof_mode_name());
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
