#include "yin.h"

#include <math.h>
#include <stdlib.h>

namespace slidepod {

Yin::Yin(float sample_rate, size_t window, float fmin_hz, float fmax_hz, float threshold)
    : sample_rate_(sample_rate), window_(window), threshold_(threshold) {
    tau_min_ = (size_t)(sample_rate / fmax_hz);
    if (tau_min_ < 2) tau_min_ = 2;
    tau_max_ = (size_t)(sample_rate / fmin_hz) + 1;
    cmnd_ = (float*)malloc(sizeof(float) * (tau_max_ + 2));
}

Yin::~Yin() { free(cmnd_); }

float Yin::detect(const float* x, float* confidence) {
    if (confidence) *confidence = 0.0f;
    if (!cmnd_) return 0.0f;

    // Step 2: difference function. Step 3: cumulative mean normalised difference.
    cmnd_[0] = 1.0f;
    float running = 0.0f;
    for (size_t tau = 1; tau <= tau_max_; ++tau) {
        float d = 0.0f;
        const float* a = x;
        const float* b = x + tau;
        for (size_t j = 0; j < window_; ++j) {
            float diff = a[j] - b[j];
            d += diff * diff;
        }
        running += d;
        cmnd_[tau] = running > 0.0f ? d * (float)tau / running : 1.0f;
    }

    // Step 4: first dip below the threshold, walked down to its local minimum.
    size_t tau = 0;
    for (size_t t = tau_min_; t < tau_max_; ++t) {
        if (cmnd_[t] < threshold_) {
            while (t + 1 < tau_max_ && cmnd_[t + 1] < cmnd_[t]) ++t;
            tau = t;
            break;
        }
    }
    if (tau == 0) return 0.0f;  // unvoiced / no clear periodicity

    // Step 5: parabolic interpolation around the minimum.
    float better = (float)tau;
    if (tau > 1 && tau < tau_max_) {
        float s0 = cmnd_[tau - 1], s1 = cmnd_[tau], s2 = cmnd_[tau + 1];
        float denom = s0 - 2.0f * s1 + s2;
        if (fabsf(denom) > 1e-9f) better += 0.5f * (s0 - s2) / denom;
    }
    if (confidence) {
        float c = 1.0f - cmnd_[tau];
        *confidence = c < 0.0f ? 0.0f : (c > 1.0f ? 1.0f : c);
    }
    return sample_rate_ / better;
}

static Biquad rbj(float fs, float fc, float q, bool high) {
    float w0 = 2.0f * (float)M_PI * fc / fs;
    float cw = cosf(w0), alpha = sinf(w0) / (2.0f * q);
    float a0 = 1.0f + alpha;
    Biquad f;
    if (high) {
        f.b0 = (1.0f + cw) / 2.0f / a0;
        f.b1 = -(1.0f + cw) / a0;
    } else {
        f.b0 = (1.0f - cw) / 2.0f / a0;
        f.b1 = (1.0f - cw) / a0;
    }
    f.b2 = f.b0;
    f.a1 = -2.0f * cw / a0;
    f.a2 = (1.0f - alpha) / a0;
    return f;
}

Biquad Biquad::highpass(float fs, float fc, float q) { return rbj(fs, fc, q, true); }
Biquad Biquad::lowpass(float fs, float fc, float q) { return rbj(fs, fc, q, false); }

}  // namespace slidepod
