#pragma once
// Calibration persisted in NVS.

#include "slide_model.h"

namespace settings {

// Loads the stored calibration into cal. Returns true if one was stored (else defaults).
bool load(slidepod::SlideCalibration& cal);
void save(const slidepod::SlideCalibration& cal);
void clear();

}  // namespace settings
