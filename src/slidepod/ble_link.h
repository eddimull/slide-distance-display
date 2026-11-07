#pragma once
// BLE GATT service (protocol in lib/slidepod_core/src/protocol.h, docs/PROTOCOL.md).

#include <stddef.h>
#include <stdint.h>

#include "protocol.h"

namespace ble_link {

void begin(const char* name);
bool connected();
void notifyState(const slidepod::State& s);
void setCalibration(const slidepod::SlideCalibration& cal);  // updates the readable value

// Writes from the app are queued here and handled in the main loop, which knows the
// current distance.
struct Pending {
    bool calibration_written = false;
    slidepod::SlideCalibration calibration;
    bool control = false;
    uint8_t control_bytes[4] = {0};
    size_t control_len = 0;
};
bool takePending(Pending& out);

}  // namespace ble_link
