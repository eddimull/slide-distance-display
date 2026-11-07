// Host-side tests for lib/slidepod_core:  pio test -e native
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unity.h>

#include <initializer_list>

#include "battery.h"
#include "protocol.h"
#include "slide_model.h"
#include "tuning.h"
#include "yin.h"

using namespace slidepod;

void setUp() {}
void tearDown() {}

// ---------------------------------------------------------------- slide model
static void test_position_roundtrip() {
    SlideCalibration cal;
    for (float p = 1.0f; p <= 7.0f; p += 0.25f) {
        float d = distanceFromPosition(cal, p);
        TEST_ASSERT_FLOAT_WITHIN(1e-3f, p, positionFromDistance(cal, d));
    }
}

static void test_position_spacing_grows() {
    // Each position is further out than the last: about 82 mm for 1->2, 110 mm for 6->7
    SlideCalibration cal;
    cal.d1_mm = 0;
    float prev_gap = 0;
    for (int p = 2; p <= 7; ++p) {
        float gap = distanceFromPosition(cal, p) - distanceFromPosition(cal, p - 1);
        TEST_ASSERT_TRUE(gap > prev_gap);
        prev_gap = gap;
    }
    TEST_ASSERT_FLOAT_WITHIN(1.0f, 81.8f, distanceFromPosition(cal, 2));
    TEST_ASSERT_FLOAT_WITHIN(2.0f, 569.5f, distanceFromPosition(cal, 7));
}

static void test_short_reading_clamps_to_first() {
    SlideCalibration cal;
    TEST_ASSERT_EQUAL_FLOAT(1.0f, positionFromDistance(cal, cal.d1_mm - 20));
}

static void test_two_point_calibration() {
    SlideCalibration truth;
    truth.d1_mm = 62.0f;
    truth.tube_mm = 2610.0f;  // a shorter horn than the default
    SlideCalibration cal;
    TEST_ASSERT_TRUE(calibrateTwoPoint(cal, truth.d1_mm, 6, distanceFromPosition(truth, 6)));
    TEST_ASSERT_FLOAT_WITHIN(0.5f, truth.tube_mm, cal.tube_mm);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 4.0f, positionFromDistance(cal, distanceFromPosition(truth, 4)));
    // nonsense: position 6 reading shorter than 1st
    TEST_ASSERT_FALSE(calibrateTwoPoint(cal, 100, 6, 90));
    TEST_ASSERT_FALSE(calibrateTwoPoint(cal, 100, 1, 300));
}

// ---------------------------------------------------------------- tuning
static void test_partial_and_note() {
    SlideCalibration cal;  // Bb tenor
    // F3 in 1st position is the 3rd partial
    TuningResult r = analyze(cal, 1.0f, midiToHz(53));
    TEST_ASSERT_TRUE(r.valid);
    TEST_ASSERT_EQUAL_UINT8(3, r.partial);
    TEST_ASSERT_EQUAL_UINT8(53, r.midi);
    TEST_ASSERT_FLOAT_WITHIN(0.05f, 1.0f, r.ideal_position);  // 3rd partial ~2 cents sharp

    // G3 in 4th position is the 4th partial and in tune there
    r = analyze(cal, 4.0f, midiToHz(55));
    TEST_ASSERT_EQUAL_UINT8(4, r.partial);
    TEST_ASSERT_FLOAT_WITHIN(0.01f, 4.0f, r.ideal_position);
}

static void test_fifth_partial_is_flat() {
    // D4 in 1st position (5th partial) is ~14 cents flat: the in-tune slide spot is
    // *inside* 1st position, which is why players lip it up or use a short 1st.
    SlideCalibration cal;
    TuningResult r = analyze(cal, 1.0f, midiToHz(62));
    TEST_ASSERT_EQUAL_UINT8(5, r.partial);
    TEST_ASSERT_FLOAT_WITHIN(0.02f, 1.0f - 0.1369f, r.ideal_position);
    TEST_ASSERT_TRUE(r.correction < 0);
}

static void test_cents_sign() {
    SlideCalibration cal;
    TuningResult r = analyze(cal, 1.0f, midiToHz(58) * exp2f(10.0f / 1200.0f));  // Bb3 +10c
    TEST_ASSERT_EQUAL_UINT8(58, r.midi);
    TEST_ASSERT_FLOAT_WITHIN(0.1f, 10.0f, r.cents);
}

static void test_no_pitch() {
    SlideCalibration cal;
    TEST_ASSERT_FALSE(analyze(cal, 3.0f, 0.0f).valid);
}

static void test_note_names() {
    char buf[8];
    noteName(58, buf, sizeof buf);
    TEST_ASSERT_EQUAL_STRING("Bb3", buf);
    noteName(60, buf, sizeof buf);
    TEST_ASSERT_EQUAL_STRING("C4", buf);
}

// ---------------------------------------------------------------- YIN
static const float FS = 16000.0f;

static float run_yin(float (*gen)(float t, void*), void* ctx, float* conf) {
    Yin yin(FS, 1024);
    size_t n = yin.requiredSamples();
    float* buf = (float*)malloc(n * sizeof(float));
    for (size_t i = 0; i < n; ++i) buf[i] = gen(i / FS, ctx);
    float f = yin.detect(buf, conf);
    free(buf);
    return f;
}

static float gen_sine(float t, void* ctx) { return sinf(2 * (float)M_PI * *(float*)ctx * t); }

// brass-like: weak fundamental, strong 2nd-5th harmonics
static float gen_brass(float t, void* ctx) {
    float f = *(float*)ctx;
    const float amp[] = {0.15f, 1.0f, 0.8f, 0.6f, 0.4f, 0.25f};
    float s = 0;
    for (int h = 0; h < 6; ++h) s += amp[h] * sinf(2 * (float)M_PI * f * (h + 1) * t + h);
    return s;
}

static float gen_noise(float, void*) { return (rand() / (float)RAND_MAX) * 2 - 1; }

static void test_yin_sine() {
    float conf;
    for (float f : {58.27f, 116.54f, 233.08f, 466.16f}) {
        float est = run_yin(gen_sine, &f, &conf);
        TEST_ASSERT_FLOAT_WITHIN(f * 0.003f, f, est);  // within ~5 cents
        TEST_ASSERT_TRUE(conf > 0.9f);
    }
}

static void test_yin_weak_fundamental() {
    float conf;
    for (float f : {87.3f, 116.54f, 174.6f}) {
        float est = run_yin(gen_brass, &f, &conf);
        TEST_ASSERT_FLOAT_WITHIN(f * 0.005f, f, est);  // no octave error
    }
}

static void test_yin_noise_unvoiced() {
    srand(1);
    float conf;
    float est = run_yin(gen_noise, nullptr, &conf);
    TEST_ASSERT_EQUAL_FLOAT(0.0f, est);
}

static void test_biquad_highpass_kills_dc() {
    Biquad hp = Biquad::highpass(FS, 35.0f);
    float y = 0;
    for (int i = 0; i < 16000; ++i) y = hp.process(1.0f);
    TEST_ASSERT_FLOAT_WITHIN(1e-3f, 0.0f, y);
}

// ---------------------------------------------------------------- protocol
static void test_state_packet() {
    State s;
    s.flags = kFlagSlideValid | kFlagPitchValid;
    s.distance_mm = 0x1234;
    s.position = 3.5f;
    s.pitch_hz = 233.08f;
    s.cents = -12.4f;
    s.midi = 58;
    s.partial = 4;
    s.confidence = 1.0f;
    s.correction = -0.25f;
    s.battery_pct = 87;
    uint8_t b[kStatePacketSize];
    TEST_ASSERT_EQUAL(kStatePacketSize, encodeState(s, b));
    TEST_ASSERT_EQUAL_UINT8(kProtocolVersion, b[0]);
    TEST_ASSERT_EQUAL_UINT8(0x34, b[2]);
    TEST_ASSERT_EQUAL_UINT8(0x12, b[3]);
    TEST_ASSERT_EQUAL_UINT16(896, b[4] | (b[5] << 8));    // 3.5 * 256
    TEST_ASSERT_EQUAL_UINT16(2331, b[6] | (b[7] << 8));   // 0.1 Hz units
    TEST_ASSERT_EQUAL_INT8(-12, (int8_t)b[8]);
    TEST_ASSERT_EQUAL_UINT8(255, b[11]);
    TEST_ASSERT_EQUAL_INT16(-64, (int16_t)(b[12] | (b[13] << 8)));
    TEST_ASSERT_EQUAL_UINT8(87, b[14]);
}

static void test_calibration_packet_roundtrip() {
    SlideCalibration c;
    c.d1_mm = 48.5f;
    c.tube_mm = 2700.0f;
    c.open_midi = 39;
    uint8_t b[kCalibrationPacketSize];
    encodeCalibration(c, b);
    SlideCalibration d;
    TEST_ASSERT_TRUE(decodeCalibration(b, sizeof b, &d));
    TEST_ASSERT_EQUAL_FLOAT(48.5f, d.d1_mm);
    TEST_ASSERT_EQUAL_FLOAT(2700.0f, d.tube_mm);
    TEST_ASSERT_EQUAL_UINT8(39, d.open_midi);
    b[0] = 99;  // wrong version
    TEST_ASSERT_FALSE(decodeCalibration(b, sizeof b, &d));
}

static void test_battery_curve() {
    TEST_ASSERT_EQUAL_UINT8(0, batteryPercent(3.2f));
    TEST_ASSERT_EQUAL_UINT8(100, batteryPercent(4.25f));
    TEST_ASSERT_TRUE(batteryPercent(3.9f) > batteryPercent(3.75f));
}

int main(int, char**) {
    UNITY_BEGIN();
    RUN_TEST(test_position_roundtrip);
    RUN_TEST(test_position_spacing_grows);
    RUN_TEST(test_short_reading_clamps_to_first);
    RUN_TEST(test_two_point_calibration);
    RUN_TEST(test_partial_and_note);
    RUN_TEST(test_fifth_partial_is_flat);
    RUN_TEST(test_cents_sign);
    RUN_TEST(test_no_pitch);
    RUN_TEST(test_note_names);
    RUN_TEST(test_yin_sine);
    RUN_TEST(test_yin_weak_fundamental);
    RUN_TEST(test_yin_noise_unvoiced);
    RUN_TEST(test_biquad_highpass_kills_dc);
    RUN_TEST(test_state_packet);
    RUN_TEST(test_calibration_packet_roundtrip);
    RUN_TEST(test_battery_curve);
    return UNITY_END();
}
