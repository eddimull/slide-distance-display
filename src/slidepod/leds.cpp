#include "leds.h"

#include <Arduino.h>
#include <math.h>

#include "pins.h"

namespace leds {

static const int kChannels[3] = {0, 1, 2};
static const int kPins[3] = {PIN_LED_R, PIN_LED_G, PIN_LED_B};
// Per-colour scale to roughly balance perceived brightness: red runs at ~1.3 mA through
// 1k, green/blue at several mA through 33R.
static const float kBalance[3] = {1.0f, 0.35f, 0.5f};
static const uint8_t kMaxDuty = 160;

struct Rgb {
    uint8_t r, g, b;
};

static const Rgb kPositionColours[7] = {
    {255, 255, 255},  // 1 white
    {255, 0, 0},      // 2 red
    {255, 90, 0},     // 3 orange
    {255, 200, 0},    // 4 yellow
    {0, 255, 0},      // 5 green
    {0, 0, 255},      // 6 blue
    {170, 0, 255},    // 7 violet
};

static void write(Rgb c) {
    const uint8_t v[3] = {c.r, c.g, c.b};
    for (int i = 0; i < 3; ++i) {
        uint32_t duty = (uint32_t)(v[i] * kBalance[i] * kMaxDuty / 255.0f);
        ledcWrite(kChannels[i], 255 - duty);  // active low
    }
}

void begin() {
    for (int i = 0; i < 3; ++i) {
        ledcSetup(kChannels[i], 5000, 8);
        ledcAttachPin(kPins[i], kChannels[i]);
    }
    write({0, 0, 0});
}

void update(float position, bool connected, uint8_t battery_pct, bool usb_power, Mode mode) {
    uint32_t now = millis();
    if (mode == Mode::SensorFault) {
        write((now / 125) % 2 ? Rgb{255, 0, 0} : Rgb{0, 0, 0});
        return;
    }
    if (battery_pct < 10 && !usb_power) {
        write((now / 500) % 2 ? Rgb{255, 0, 0} : Rgb{0, 0, 0});
        return;
    }
    if (!connected && (now % 2000) < 80) {
        write({0, 0, 255});
        return;
    }
    if (position <= 0.0f) {
        write({0, 0, 0});
        return;
    }
    int idx = (int)lroundf(position) - 1;
    if (idx < 0) idx = 0;
    if (idx > 6) idx = 6;
    write(kPositionColours[idx]);
}

}  // namespace leds
