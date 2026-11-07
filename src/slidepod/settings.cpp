#include "settings.h"

#include <Preferences.h>

namespace settings {

static const char* kNamespace = "slidepod";

bool load(slidepod::SlideCalibration& cal) {
    Preferences p;
    p.begin(kNamespace, true);
    bool stored = p.getBool("cal", false);
    if (stored) {
        cal.d1_mm = p.getFloat("d1", cal.d1_mm);
        cal.tube_mm = p.getFloat("tube", cal.tube_mm);
        cal.open_midi = p.getUChar("midi", cal.open_midi);
    }
    p.end();
    return stored;
}

void save(const slidepod::SlideCalibration& cal) {
    Preferences p;
    p.begin(kNamespace, false);
    p.putFloat("d1", cal.d1_mm);
    p.putFloat("tube", cal.tube_mm);
    p.putUChar("midi", cal.open_midi);
    p.putBool("cal", true);
    p.end();
}

void clear() {
    Preferences p;
    p.begin(kNamespace, false);
    p.clear();
    p.end();
}

}  // namespace settings
