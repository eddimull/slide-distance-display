#pragma once
/*
 * YIN pitch detector (de Cheveigné & Kawahara, 2002), sized for a trombone
 * piezo pickup. Plain C++, no Arduino dependencies, so it can be unit-tested
 * on the host (test/pitch_yin/).
 *
 * Feed samples with push(); call detect() once per hop. The caller owns
 * timing: on hardware that's the ADC DMA task, ~every 20 ms.
 */

#include <math.h>
#include <stdint.h>
#include <string.h>

class PitchYin {
 public:
  // 16 kHz: at 8 kHz an F5 period is only ~11 samples, and YIN's
  // integer-lag difference function misses it and lands an octave low.
  static constexpr float kSampleRate = 16000.0f;
  static constexpr float kMinHz = 50.0f;    // just below the Bb1 pedal (58 Hz)
  static constexpr float kMaxHz = 1000.0f;  // well above a high Bb5 (932 Hz)
  static constexpr int kWindow = 768;       // 48 ms: 2.4 periods of 50 Hz
  static constexpr int kTauMin = (int)(kSampleRate / kMaxHz);
  static constexpr int kTauMax = (int)(kSampleRate / kMinHz);
  static constexpr int kIntegrate = kWindow - kTauMax;

  // Absolute YIN threshold: lower = stricter about periodicity.
  float threshold = 0.15f;
  // Below this RMS (in ADC counts, after DC removal) the horn isn't
  // sounding and we report 0. Tune once real piezo levels are known.
  float minRms = 8.0f;

  /// Add one raw ADC sample (0–4095, mid-rail ≈ 2048).
  void push(float raw) {
    // One-pole high-pass (~20 Hz) removes the mid-rail bias and drift,
    // one-pole low-pass (~1.2 kHz) knocks down hiss and upper harmonics
    // that otherwise tempt YIN toward octave-up errors.
    const float hp = kHpA * (hpPrevOut_ + raw - hpPrevIn_);
    hpPrevIn_ = raw;
    hpPrevOut_ = hp;
    lp_ += kLpA * (hp - lp_);
    buf_[head_] = lp_;
    head_ = (head_ + 1) % kWindow;
    if (filled_ < kWindow) filled_++;
  }

  /// Returns the fundamental in Hz, or 0 if there's no clear pitch.
  /// Also sets rms() for the window that was analysed.
  float detect() {
    if (filled_ < kWindow) return 0;

    // Unroll the ring buffer into analysis order.
    for (int i = 0; i < kWindow; i++) win_[i] = buf_[(head_ + i) % kWindow];

    float sumSq = 0;
    for (int i = 0; i < kWindow; i++) sumSq += win_[i] * win_[i];
    rms_ = sqrtf(sumSq / kWindow);
    if (rms_ < minRms) return 0;

    // Step 2–3: difference function, cumulative-mean normalised.
    d_[0] = 1.0f;
    float running = 0;
    for (int tau = 1; tau <= kTauMax; tau++) {
      float sum = 0;
      for (int i = 0; i < kIntegrate; i++) {
        const float delta = win_[i] - win_[i + tau];
        sum += delta * delta;
      }
      running += sum;
      d_[tau] = running > 0 ? sum * tau / running : 1.0f;
    }

    // Step 4: first dip under the threshold, then walk to its bottom.
    int tau = -1;
    for (int t = kTauMin; t < kTauMax; t++) {
      if (d_[t] < threshold) {
        while (t + 1 < kTauMax && d_[t + 1] < d_[t]) t++;
        tau = t;
        break;
      }
    }
    if (tau < 0) return 0;

    // Step 5: parabolic interpolation for sub-sample period.
    float betterTau = (float)tau;
    if (tau > kTauMin && tau < kTauMax) {
      const float s0 = d_[tau - 1], s1 = d_[tau], s2 = d_[tau + 1];
      const float denom = s0 - 2 * s1 + s2;
      if (fabsf(denom) > 1e-9f) betterTau += 0.5f * (s0 - s2) / denom;
    }
    return kSampleRate / betterTau;
  }

  float rms() const { return rms_; }

 private:
  // RC constants for the one-pole filters at kSampleRate.
  static constexpr float kHpA = 0.99218f;  // exp(-2π·20/16000)
  static constexpr float kLpA = 0.37572f;  // 1 - exp(-2π·1200/16000)

  float buf_[kWindow] = {};
  float win_[kWindow] = {};
  float d_[kTauMax + 1] = {};
  int head_ = 0;
  int filled_ = 0;
  float hpPrevIn_ = 0, hpPrevOut_ = 0, lp_ = 0;
  float rms_ = 0;
};
