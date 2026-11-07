#pragma once
// 1S LiPo state of charge from resting voltage (piecewise-linear, typical discharge curve).
// Rough under load; good enough for a percentage readout and a low-battery warning.

#include <stdint.h>

namespace slidepod {

inline uint8_t batteryPercent(float volts) {
    static const float v[] = {3.30f, 3.60f, 3.70f, 3.75f, 3.80f, 3.85f, 3.95f, 4.05f, 4.20f};
    static const float p[] = {0.0f, 5.0f, 12.0f, 25.0f, 40.0f, 55.0f, 70.0f, 85.0f, 100.0f};
    const int n = sizeof(v) / sizeof(v[0]);
    if (volts <= v[0]) return 0;
    if (volts >= v[n - 1]) return 100;
    for (int i = 1; i < n; ++i) {
        if (volts < v[i]) {
            float t = (volts - v[i - 1]) / (v[i] - v[i - 1]);
            return (uint8_t)(p[i - 1] + t * (p[i] - p[i - 1]) + 0.5f);
        }
    }
    return 100;
}

}  // namespace slidepod
