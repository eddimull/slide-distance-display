#include "tuning.h"

#include <math.h>
#include <stdio.h>

namespace slidepod {

float midiToHz(float midi) { return 440.0f * exp2f((midi - 69.0f) / 12.0f); }

float hzToMidi(float hz) { return 69.0f + 12.0f * log2f(hz / 440.0f); }

TuningResult analyze(const SlideCalibration& cal, float position, float f_hz) {
    TuningResult r;
    if (!(f_hz > 20.0f)) return r;

    float f_open = midiToHz(cal.open_midi);
    float f0 = f_open * exp2f(-(position - 1.0f) / 12.0f);
    int n = (int)lroundf(f_hz / f0);
    if (n < 1 || n > 16) return r;

    int midi = (int)lroundf(hzToMidi(f_hz));
    if (midi < 0 || midi > 127) return r;

    r.valid = true;
    r.partial = (uint8_t)n;
    r.midi = (uint8_t)midi;
    r.cents = 1200.0f * log2f(f_hz / midiToHz((float)midi));
    r.ideal_position = 1.0f + 12.0f * log2f(n * f_open / midiToHz((float)midi));
    r.correction = r.ideal_position - position;
    r.reachable = r.ideal_position > 0.7f && r.ideal_position < 7.5f;
    return r;
}

void noteName(uint8_t midi, char* out, int out_len) {
    static const char* names[12] = {"C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"};
    snprintf(out, out_len, "%s%d", names[midi % 12], midi / 12 - 1);
}

}  // namespace slidepod
