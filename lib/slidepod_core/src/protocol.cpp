#include "protocol.h"

#include <math.h>
#include <string.h>

namespace slidepod {

static void put16(uint8_t* p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)(v >> 8);
}

static uint16_t clampU16(float v) {
    if (!(v > 0.0f)) return 0;
    if (v > 65535.0f) return 65535;
    return (uint16_t)lroundf(v);
}

static int16_t clampI16(float v) {
    if (v > 32767.0f) return 32767;
    if (v < -32768.0f) return -32768;
    return (int16_t)lroundf(v);
}

size_t encodeState(const State& s, uint8_t* out) {
    out[0] = kProtocolVersion;
    out[1] = s.flags;
    put16(out + 2, s.distance_mm);
    put16(out + 4, clampU16(s.position * 256.0f));
    put16(out + 6, clampU16(s.pitch_hz * 10.0f));
    float c = s.cents > 127.0f ? 127.0f : (s.cents < -127.0f ? -127.0f : s.cents);
    out[8] = (uint8_t)(int8_t)lroundf(c);
    out[9] = s.midi;
    out[10] = s.partial;
    out[11] = (uint8_t)lroundf((s.confidence < 0 ? 0 : (s.confidence > 1 ? 1 : s.confidence)) * 255.0f);
    put16(out + 12, (uint16_t)clampI16(s.correction * 256.0f));
    out[14] = s.battery_pct;
    return kStatePacketSize;
}

size_t encodeCalibration(const SlideCalibration& c, uint8_t* out) {
    out[0] = kProtocolVersion;
    memcpy(out + 1, &c.d1_mm, 4);    // little-endian on ESP32, ARM and x86
    memcpy(out + 5, &c.tube_mm, 4);
    out[9] = c.open_midi;
    return kCalibrationPacketSize;
}

bool decodeCalibration(const uint8_t* in, size_t len, SlideCalibration* c) {
    if (len < kCalibrationPacketSize || in[0] != kProtocolVersion) return false;
    SlideCalibration t;
    memcpy(&t.d1_mm, in + 1, 4);
    memcpy(&t.tube_mm, in + 5, 4);
    t.open_midi = in[9];
    if (!(t.d1_mm >= 0.0f && t.d1_mm < 500.0f)) return false;
    if (!(t.tube_mm > 1200.0f && t.tube_mm < 4500.0f)) return false;
    if (t.open_midi < 20 || t.open_midi > 50) return false;
    *c = t;
    return true;
}

}  // namespace slidepod
