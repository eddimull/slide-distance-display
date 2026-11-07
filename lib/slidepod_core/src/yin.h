#pragma once
// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002).
//
// Robust to the weak fundamental of brass tones: it looks for the shortest lag at which
// the waveform repeats, not for the loudest spectral peak.
//
// Cost is O(window * max_lag) per call: 1024 x 400 at 16 kHz is ~0.4 M multiply-adds,
// a few ms on the ESP32-S3.

#include <stddef.h>

namespace slidepod {

class Yin {
public:
    // fmin/fmax bound the search (trombone: pedal E1 ~41 Hz up to ~F5 700 Hz).
    Yin(float sample_rate, size_t window, float fmin_hz = 38.0f, float fmax_hz = 1000.0f,
        float threshold = 0.15f);
    ~Yin();

    // Samples needed per call: window + max lag.
    size_t requiredSamples() const { return window_ + tau_max_ + 1; }

    // Returns the pitch in Hz, or 0 when the frame is unvoiced. confidence is 1 - the
    // normalised difference at the chosen lag (1 = perfectly periodic).
    float detect(const float* x, float* confidence);

private:
    float sample_rate_;
    size_t window_, tau_min_, tau_max_;
    float threshold_;
    float* cmnd_;
};

// Second-order IIR section (direct form I), coefficients from the RBJ cookbook.
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float x1 = 0, x2 = 0, y1 = 0, y2 = 0;

    static Biquad highpass(float fs, float fc, float q = 0.7071f);
    static Biquad lowpass(float fs, float fc, float q = 0.7071f);

    float process(float x) {
        float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x;
        y2 = y1; y1 = y;
        return y;
    }
};

}  // namespace slidepod
