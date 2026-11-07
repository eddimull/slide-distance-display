#pragma once
// Combines slide position and played pitch into: which partial is sounding, which
// note it is, how far from equal temperament, and where the slide *should* be to
// play that note in tune on that partial.
//
// The horn's series in a given position is f0(p) = f_open * 2^(-(p - 1) / 12), with
// f_open the pedal in 1st position. Partial n sounds n * f0(p). Because the natural
// series is not equal-tempered (5th partial ~14 cents flat, 7th ~31 cents flat), the
// in-tune slide spot for a note differs per partial:
//
//   p* = 1 + 12 * log2(n * f_open / f_ET(note))

#include <stdint.h>

#include "slide_model.h"

namespace slidepod {

float midiToHz(float midi);
float hzToMidi(float hz);

struct TuningResult {
    bool valid = false;        // a partial and note were identified
    uint8_t partial = 0;       // 1 = pedal
    uint8_t midi = 0;          // nearest equal-tempered note
    float cents = 0.0f;        // played pitch vs that note, + = sharp
    float ideal_position = 0;  // slide spot that plays the note in tune on this partial
    float correction = 0;      // ideal_position - current position (+ = move the slide out)
    bool reachable = false;    // ideal position lies on the slide (about 0.7 .. 7.5)
};

// position: current continuous slide position; f_hz: detected pitch (0 = none).
TuningResult analyze(const SlideCalibration& cal, float position, float f_hz);

// Note name like "Bb3" for a MIDI number (flats, trombone style).
void noteName(uint8_t midi, char* out, int out_len);

}  // namespace slidepod
