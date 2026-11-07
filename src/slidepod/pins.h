#pragma once
// SlidePod rev 0.1 pin map (hardware/README.md, hardware/tools/circuit.py).

constexpr int PIN_PIEZO_ADC = 1;    // ADC1_CH0: MCP6001 output, mid-rail biased
constexpr int PIN_VBAT_SENSE = 2;   // ADC1_CH1: VBAT / 2 (1M/1M)
constexpr int PIN_TOF_INT = 4;      // VL53L1X GPIO1, open-drain, active low
constexpr int PIN_TOF_XSHUT = 5;    // VL53L1X shutdown, low = off
constexpr int PIN_I2C_SDA = 8;
constexpr int PIN_I2C_SCL = 9;
constexpr int PIN_VBUS_SENSE = 10;  // ADC1_CH9: VBUS / 2 (100k/100k)
constexpr int PIN_LED_R = 11;       // LEDs: anode to 3V3, GPIO sinks (active low)
constexpr int PIN_LED_G = 12;
constexpr int PIN_LED_B = 13;
constexpr int PIN_BOOT = 0;

// ADC1 channel numbers of the analog pins above (ESP32-S3: GPIOn -> ADC1_CH(n-1)).
constexpr int ADC_CH_PIEZO = 0;
constexpr int ADC_CH_VBAT = 1;
constexpr int ADC_CH_VBUS = 9;
