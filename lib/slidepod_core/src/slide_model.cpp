#include "slide_model.h"

#include <math.h>

namespace slidepod {

float positionFromDistance(const SlideCalibration& cal, float distance_mm) {
    float extension = distance_mm - cal.d1_mm;
    if (extension <= 0.0f) return 1.0f;
    return 1.0f + 12.0f * log2f(1.0f + 2.0f * extension / cal.tube_mm);
}

float distanceFromPosition(const SlideCalibration& cal, float position) {
    return cal.d1_mm + 0.5f * cal.tube_mm * (exp2f((position - 1.0f) / 12.0f) - 1.0f);
}

bool calibrateTwoPoint(SlideCalibration& cal, float d1_mm, int k, float dk_mm) {
    if (k < 2 || k > 7) return false;
    float extension = dk_mm - d1_mm;
    float ratio = exp2f((k - 1) / 12.0f) - 1.0f;
    float tube = 2.0f * extension / ratio;
    // Sanity range: alto (~1.7 m) to bass/contrabass-ish lengths.
    if (!(tube > 1200.0f && tube < 4500.0f)) return false;
    cal.d1_mm = d1_mm;
    cal.tube_mm = tube;
    return true;
}

}  // namespace slidepod
