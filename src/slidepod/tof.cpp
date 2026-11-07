#include "tof.h"

#include <Arduino.h>
#include <SimpleKalmanFilter.h>
#include <VL53L1X.h>
#include <Wire.h>

#include "pins.h"

namespace tof {

static VL53L1X sensor;
static bool sensor_ok = false;
// measurement error ~3 mm, initial estimate error 3 mm, process noise sized for a slide
// that moves up to ~1 m/s (fast enough to follow, smooth enough to read a position)
static SimpleKalmanFilter kalman(3.0f, 3.0f, 0.6f);
static float filtered = 0, raw = 0;
static uint32_t last_valid = 0;
static bool primed = false;

bool begin() {
    pinMode(PIN_TOF_XSHUT, OUTPUT);
    digitalWrite(PIN_TOF_XSHUT, LOW);   // hard reset
    delay(5);
    digitalWrite(PIN_TOF_XSHUT, HIGH);
    delay(5);
    pinMode(PIN_TOF_INT, INPUT_PULLUP);

    Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, 400000);
    sensor.setTimeout(100);
    if (!sensor.init()) {
        sensor_ok = false;
        return false;
    }
    // Short mode: <= 1.3 m, best ambient-light immunity. 20 ms -> 50 Hz.
    sensor.setDistanceMode(VL53L1X::Short);
    sensor.setMeasurementTimingBudget(20000);
    // ~15 degree field of view so the beam stays on the reflector tab, off the tubes.
    sensor.setROISize(8, 8);
    sensor.startContinuous(20);
    sensor_ok = true;
    return true;
}

bool ok() { return sensor_ok; }

bool poll() {
    if (!sensor_ok || !sensor.dataReady()) return false;
    uint16_t mm = sensor.read(false);
    if (sensor.timeoutOccurred()) return false;
    if (sensor.ranging_data.range_status != VL53L1X::RangeValid) return false;
    raw = mm;
    if (!primed) {
        kalman.setEstimateError(3.0f);
        primed = true;
        filtered = raw;
    }
    filtered = kalman.updateEstimate(raw);
    last_valid = millis();
    return true;
}

float distanceMm() { return filtered; }
float rawMm() { return raw; }
uint32_t lastValidMs() { return last_valid; }

}  // namespace tof
