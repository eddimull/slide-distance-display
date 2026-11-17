// Host-side test for src/slidepod/pitch_yin.h.
//   g++ -O2 -std=c++17 -I src/slidepod test/pitch_yin/test_pitch_yin.cpp -o /tmp/t && /tmp/t
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "pitch_yin.h"

static int failures = 0;
static const int kHop = PitchYin::kSampleRate / 50;  // 20 ms, matches firmware

// Brass-ish tone as a piezo on the slide might see it: weak fundamental,
// strongest energy in harmonics 2–4, rolling off above. Mid-rail bias,
// white noise, and slight vibrato.
static float brassSample(float f, int n, float amp, float noise) {
  static const float h[] = {0.35f, 1.0f, 0.9f, 0.7f, 0.45f, 0.3f, 0.2f, 0.1f};
  const float t = n / PitchYin::kSampleRate;
  // ±5¢ vibrato at 5.5 Hz, phase-integrated so the mean pitch stays f.
  const float vr = 5.5f, depth = 0.003f;
  const float phase =
      2 * M_PI * f * (t - depth / (2 * M_PI * vr) * cosf(2 * M_PI * vr * t));
  float s = 0;
  for (int k = 0; k < 8; k++) {
    if (f * (k + 1) > 0.45f * PitchYin::kSampleRate) break;  // RC kills it
    s += h[k] * sinf((k + 1) * phase + k);
  }
  const float r = ((float)rand() / RAND_MAX - 0.5f) * 2 * noise;
  return 2048 + amp * s + r;
}

static float centsOff(float got, float want) {
  return 1200 * log2f(got / want);
}

// Runs ~0.5 s of tone; checks every detection after the window has filled.
static void checkNote(const char* name, float f, float amp, float noise) {
  PitchYin yin;
  int n = 0, frames = 0, bad = 0, silent = 0;
  float worst = 0;
  for (int frame = 0; frame < 25; frame++) {
    for (int i = 0; i < kHop; i++) yin.push(brassSample(f, n++, amp, noise));
    const float got = yin.detect();
    if (frame < 4) continue;  // window + filter settling
    frames++;
    if (got == 0) { silent++; continue; }
    const float c = centsOff(got, f);
    if (fabsf(c) > fabsf(worst)) worst = c;
    if (fabsf(c) > 15) bad++;
  }
  const bool ok = bad == 0 && silent <= frames / 10;
  printf("%-5s %7.2f Hz  worst %+6.1f¢  misses %d/%d  wrong %d  %s\n", name, f,
         worst, silent, frames, bad, ok ? "ok" : "FAIL");
  if (!ok) failures++;
}

int main() {
  srand(1);
  // Range of a tenor trombone's normal playing: E2 (2nd partial, 7th pos)
  // up to F5; plus the Bb1 pedal.
  checkNote("Bb1", 58.27f, 400, 20);
  checkNote("E2", 82.41f, 400, 20);
  checkNote("Bb2", 116.54f, 400, 20);
  checkNote("F3", 174.61f, 400, 20);
  checkNote("Bb3", 233.08f, 400, 20);
  checkNote("D4", 293.66f, 400, 20);
  checkNote("F4", 349.23f, 400, 20);
  checkNote("Bb4", 466.16f, 400, 20);
  checkNote("F5", 698.46f, 400, 20);
  // Quiet and noisy: SNR ~ 6 dB on the strongest harmonic.
  checkNote("F3 lo", 174.61f, 60, 30);

  // Silence (bias + a little noise) must report 0.
  PitchYin yin;
  int n = 0, falsePitch = 0;
  for (int frame = 0; frame < 25; frame++) {
    for (int i = 0; i < kHop; i++)
      yin.push(2048 + ((float)rand() / RAND_MAX - 0.5f) * 6);
    (void)n;
    if (frame >= 4 && yin.detect() != 0) falsePitch++;
  }
  printf("silence: %d false detections  %s\n", falsePitch,
         falsePitch ? "FAIL" : "ok");
  if (falsePitch) failures++;

  printf(failures ? "\n%d FAILED\n" : "\nall passed\n", failures);
  return failures ? 1 : 0;
}
