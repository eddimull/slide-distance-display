#pragma once
// Analog front end: one ADC1 DMA stream samples
//   piezo   (GPIO1) at 16 kHz -> high/low-pass -> YIN pitch every 32 ms
//   VBAT/2  (GPIO2) and VBUS/2 (GPIO10) at 8 kHz each -> averaged supply voltages
// Runs in its own FreeRTOS task on core 0.

#include <stdint.h>

namespace audio {

struct Pitch {
    float hz = 0;          // 0 = unvoiced / too quiet
    float confidence = 0;  // 0..1
    float rms = 0;         // band-passed piezo level, ADC counts (for gain tuning)
    uint32_t at_ms = 0;    // millis() when computed
};

bool begin();
Pitch latest();
float batteryVolts();
float usbVolts();
uint32_t framesProcessed();
uint32_t lastYinMicros();   // compute time of the last pitch estimate

}  // namespace audio
