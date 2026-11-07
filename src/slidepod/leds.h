#pragma once
// Status LEDs (three discrete 0603s behind a light pipe, active low, LEDC PWM).
//
//   slide in range      colour of the nearest position (1 white, 2 red, 3 orange,
//                       4 yellow, 5 green, 6 blue, 7 violet), as on the old TFT version
//   not connected       short blue blink every 2 s on top of that
//   battery < 10 %      red blink at 1 Hz (overrides everything, unless on USB)
//   sensor fault        fast red blink

#include <stdint.h>

namespace leds {

enum class Mode { Normal, SensorFault };

void begin();
// Call often (>= 20 Hz). position <= 0 means "slide not in range".
void update(float position, bool connected, uint8_t battery_pct, bool usb_power, Mode mode);

}  // namespace leds
