// SlidePod firmware: trombone slide position + pitch over BLE.
//
//   core 0: NimBLE host, audio task (ADC DMA -> filters -> YIN)
//   core 1: this loop at 50 Hz (ToF -> position, fuse with pitch, notify, LEDs)

#include <Arduino.h>

#include "audio.h"
#include "battery.h"
#include "ble_link.h"
#include "leds.h"
#include "protocol.h"
#include "settings.h"
#include "slide_model.h"
#include "tof.h"
#include "tuning.h"

using namespace slidepod;

static SlideCalibration cal;
static bool calibrated = false;
static constexpr uint32_t kTickMs = 20;          // 50 Hz
static constexpr uint32_t kSlideStaleMs = 150;   // ToF reading older than this = no slide
static constexpr uint32_t kPitchStaleMs = 100;
static constexpr float kMinConfidence = 0.6f;
static constexpr float kMaxSlideMm = 1000.0f;    // beyond 7th + margin = out of range

static void applyCalibration(const SlideCalibration& c, bool persist) {
    cal = c;
    if (persist) {
        settings::save(cal);
        calibrated = true;
    }
    ble_link::setCalibration(cal);
    Serial.printf("[cal] d1=%.1f mm  L=%.0f mm  open=MIDI %u\n", cal.d1_mm, cal.tube_mm, cal.open_midi);
}

static void handleControl(const uint8_t* b, size_t len, bool slide_valid) {
    float d = tof::distanceMm();
    switch (b[0]) {
        case kOpCaptureFirst:
            if (!slide_valid) break;
            {
                SlideCalibration c = cal;
                c.d1_mm = d;
                applyCalibration(c, true);
            }
            break;
        case kOpCapturePosition:
            if (!slide_valid || len < 2) break;
            {
                SlideCalibration c = cal;
                if (calibrateTwoPoint(c, cal.d1_mm, b[1], d)) {
                    applyCalibration(c, true);
                } else {
                    Serial.printf("[cal] rejected: position %u at %.1f mm with d1 %.1f mm\n", b[1], d, cal.d1_mm);
                }
            }
            break;
        case kOpResetCalibration:
            settings::clear();
            calibrated = false;
            applyCalibration(SlideCalibration(), false);
            break;
        case kOpSetOpenNote:
            if (len >= 2 && b[1] >= 20 && b[1] <= 50) {
                SlideCalibration c = cal;
                c.open_midi = b[1];
                applyCalibration(c, true);
            }
            break;
        default:
            Serial.printf("[ble] unknown control op 0x%02x\n", b[0]);
    }
}

void setup() {
    Serial.begin(115200);
    leds::begin();
    calibrated = settings::load(cal);

    if (!tof::begin()) Serial.println("[tof] VL53L1X not responding, will retry");
    if (!audio::begin()) Serial.println("[audio] ADC/pitch start FAILED");

    ble_link::begin("SlidePod");
    ble_link::setCalibration(cal);
    Serial.printf("SlidePod fw up. cal %s: d1=%.1f L=%.0f\n", calibrated ? "stored" : "default",
                  cal.d1_mm, cal.tube_mm);
}

void loop() {
    static uint32_t next_tick = 0, next_log = 0, next_tof_retry = 0;
    uint32_t now = millis();
    if ((int32_t)(now - next_tick) < 0) {
        tof::poll();   // keep draining the sensor between ticks
        delay(1);
        return;
    }
    next_tick = now + kTickMs;

    if (!tof::ok() && (int32_t)(now - next_tof_retry) >= 0) {
        next_tof_retry = now + 1000;
        tof::begin();
    }
    tof::poll();

    float d = tof::distanceMm();
    bool slide_valid = tof::ok() && (now - tof::lastValidMs()) < kSlideStaleMs && d < kMaxSlideMm;
    float position = slide_valid ? positionFromDistance(cal, d) : 0.0f;

    audio::Pitch p = audio::latest();
    bool pitch_valid = p.hz > 0 && (now - p.at_ms) < kPitchStaleMs && p.confidence >= kMinConfidence;

    State s;
    s.distance_mm = slide_valid ? (uint16_t)d : 0;
    s.position = position;
    s.pitch_hz = pitch_valid ? p.hz : 0;
    s.confidence = p.confidence;
    float vbat = audio::batteryVolts();
    bool usb = audio::usbVolts() > 4.0f;
    s.battery_pct = batteryPercent(vbat);
    if (slide_valid) s.flags |= kFlagSlideValid;
    if (pitch_valid) s.flags |= kFlagPitchValid;
    if (usb) s.flags |= kFlagUsbPower;
    if (calibrated) s.flags |= kFlagCalibrated;
    if (slide_valid && pitch_valid) {
        TuningResult t = analyze(cal, position, p.hz);
        if (t.valid) {
            s.flags |= kFlagNoteValid;
            if (t.reachable) s.flags |= kFlagReachable;
            s.midi = t.midi;
            s.partial = t.partial;
            s.cents = t.cents;
            s.correction = t.correction;
        }
    }
    ble_link::notifyState(s);

    ble_link::Pending pend;
    if (ble_link::takePending(pend)) {
        if (pend.calibration_written) applyCalibration(pend.calibration, true);
        if (pend.control) handleControl(pend.control_bytes, pend.control_len, slide_valid);
    }

    leds::update(position, ble_link::connected(), s.battery_pct, usb,
                 tof::ok() ? leds::Mode::Normal : leds::Mode::SensorFault);

    if ((int32_t)(now - next_log) >= 0) {
        next_log = now + 500;
        char note[8] = "-";
        if (s.flags & kFlagNoteValid) noteName(s.midi, note, sizeof note);
        Serial.printf("d=%4.0fmm (raw %4.0f) pos=%.2f | f=%6.1fHz conf=%.2f rms=%5.1f yin=%uus | %s p%u %+5.1fc corr=%+.2f | "
                      "bat=%.2fV %u%% usb=%d ble=%d\n",
                      d, tof::rawMm(), position, p.hz, p.confidence, p.rms, (unsigned)audio::lastYinMicros(),
                      note, s.partial, s.cents, s.correction, vbat, s.battery_pct, usb, ble_link::connected());
    }
}
