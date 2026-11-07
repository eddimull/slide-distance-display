#pragma once
// Slide geometry: maps a ToF distance reading to a continuous slide position (1.0 = 1st,
// 7.0 = 7th) and back.
//
// Each position lowers the pitch a semitone, multiplying the vibrating tube length by
// 2^(1/12). The slide is a U, so the slide moves half of the added length:
//
//   d(p) = d1 + (L / 2) * (2^((p - 1) / 12) - 1)
//
// d1 is the sensor reading in 1st position and L the effective tube length in 1st
// (about 2750 mm for a B-flat tenor). Two readings (1st and one other known position)
// fix both.

namespace slidepod {

struct SlideCalibration {
    float d1_mm = 50.0f;       // ToF reading with the slide in 1st position
    float tube_mm = 2750.0f;   // effective tube length L in 1st position
    unsigned char open_midi = 34;  // pedal (1st partial) in 1st position: Bb1 = MIDI 34
};

// Continuous position (>= 1.0). Readings shorter than d1 clamp to 1.0.
float positionFromDistance(const SlideCalibration& cal, float distance_mm);

// Inverse: sensor distance for a (possibly fractional) position.
float distanceFromPosition(const SlideCalibration& cal, float position);

// Two-point calibration: d1 measured in 1st position, dk measured in position k (2..7).
// Returns false (and leaves cal unchanged) if the readings are inconsistent.
bool calibrateTwoPoint(SlideCalibration& cal, float d1_mm, int k, float dk_mm);

}  // namespace slidepod
