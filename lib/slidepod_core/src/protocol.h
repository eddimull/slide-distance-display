#pragma once
// SlidePod BLE protocol v1. All multi-byte fields little-endian. The Flutter app
// mirrors these layouts; see docs/PROTOCOL.md.

#include <stddef.h>
#include <stdint.h>

#include "slide_model.h"

namespace slidepod {

// Service and characteristic UUIDs (128-bit, random base 5d1e....-7c3a-4b8e-9f21-6a0c2e4b7d90).
#define SLIDEPOD_SERVICE_UUID     "5d1e0000-7c3a-4b8e-9f21-6a0c2e4b7d90"
#define SLIDEPOD_STATE_UUID       "5d1e0001-7c3a-4b8e-9f21-6a0c2e4b7d90"  // notify, 50 Hz
#define SLIDEPOD_CALIBRATION_UUID "5d1e0002-7c3a-4b8e-9f21-6a0c2e4b7d90"  // read / write
#define SLIDEPOD_CONTROL_UUID     "5d1e0003-7c3a-4b8e-9f21-6a0c2e4b7d90"  // write

constexpr uint8_t kProtocolVersion = 1;

enum StateFlags : uint8_t {
    kFlagSlideValid = 1 << 0,   // ToF reading is fresh and in range
    kFlagPitchValid = 1 << 1,   // a pitch was detected this frame
    kFlagNoteValid = 1 << 2,    // partial / note / correction fields are meaningful
    kFlagReachable = 1 << 3,    // the in-tune position for this note lies on the slide
    kFlagUsbPower = 1 << 4,     // USB present (charging or full)
    kFlagCalibrated = 1 << 5,   // user calibration stored (otherwise defaults)
};

struct State {
    uint8_t flags = 0;
    uint16_t distance_mm = 0;   // filtered ToF distance
    float position = 0;         // continuous slide position, 1.0 .. ~8
    float pitch_hz = 0;
    float cents = 0;            // vs nearest equal-tempered note
    uint8_t midi = 0;
    uint8_t partial = 0;
    float confidence = 0;       // 0..1
    float correction = 0;       // ideal - current position (+ = move out)
    uint8_t battery_pct = 0;
};

constexpr size_t kStatePacketSize = 15;
// [0] version  [1] flags  [2..3] distance_mm  [4..5] position*256  [6..7] pitch*10 (0.1 Hz)
// [8] cents (int8, clamped to +-127)  [9] midi  [10] partial  [11] confidence*255
// [12..13] correction*256 (int16)  [14] battery %
size_t encodeState(const State& s, uint8_t* out);

constexpr size_t kCalibrationPacketSize = 10;
// [0] version  [1..4] d1_mm (float32)  [5..8] tube_mm (float32)  [9] open_midi
size_t encodeCalibration(const SlideCalibration& c, uint8_t* out);
bool decodeCalibration(const uint8_t* in, size_t len, SlideCalibration* c);

// Control opcodes (first byte of a write to the control characteristic)
enum ControlOp : uint8_t {
    kOpCaptureFirst = 0x01,     // store the current distance as 1st position
    kOpCapturePosition = 0x02,  // [1] = k (2..7): current distance is position k, solve L
    kOpResetCalibration = 0x03, // back to defaults
    kOpSetOpenNote = 0x04,      // [1] = MIDI of the pedal in 1st (Bb1 = 34, Eb alto = 39, F = 29)
};

}  // namespace slidepod
