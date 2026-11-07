#pragma once
// VL53L1X slide-distance sensor: Short mode, 20 ms budget (50 Hz), narrowed ROI,
// Kalman-filtered.

#include <stdint.h>

namespace tof {

bool begin();          // false if the sensor doesn't answer
bool ok();

// Polls the sensor. Returns true when a new valid reading was folded into the filter.
bool poll();

float distanceMm();    // filtered
float rawMm();         // last raw reading
uint32_t lastValidMs();  // millis() of the last valid reading

}  // namespace tof
