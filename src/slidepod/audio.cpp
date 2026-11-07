#include "audio.h"

#include <Arduino.h>
#include <driver/adc.h>
#include <esp_adc_cal.h>
#include <math.h>

#include "pins.h"
#include "yin.h"

namespace audio {

using slidepod::Biquad;
using slidepod::Yin;

static constexpr uint32_t kConvRate = 32000;     // conversions/s across the 4-slot pattern
static constexpr float kPiezoRate = 16000.0f;    // piezo occupies 2 of 4 slots
static constexpr size_t kWindow = 1024;          // YIN integration window (64 ms)
static constexpr size_t kHop = 512;              // new estimate every 32 ms
static constexpr size_t kRing = 2048;            // >= window + max lag
static constexpr size_t kDmaFrameBytes = 1024;   // 256 conversions = 8 ms
static constexpr float kMinRms = 12.0f;          // gate: quieter than this is "no note"

static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
static Pitch shared;
static float vbat = 0, vbus = 0;
static volatile uint32_t frames = 0, yin_us = 0;

static float ring[kRing];
static size_t ring_pos = 0, since_hop = 0, filled = 0;
static float frame[kRing];
static Yin* yin = nullptr;
static Biquad hp1, hp2, lp1, lp2;
static esp_adc_cal_characteristics_t adc_chars;

static bool startAdc() {
    adc_digi_init_config_t init = {};
    init.max_store_buf_size = 8 * kDmaFrameBytes;
    init.conv_num_each_intr = kDmaFrameBytes;
    init.adc1_chan_mask = BIT(ADC_CH_PIEZO) | BIT(ADC_CH_VBAT) | BIT(ADC_CH_VBUS);
    init.adc2_chan_mask = 0;
    if (adc_digi_initialize(&init) != ESP_OK) return false;

    // Pattern: piezo, vbat, piezo, vbus. The piezo is sampled every other slot, so its
    // spacing stays uniform at kConvRate / 2.
    static adc_digi_pattern_config_t pattern[4];
    const int chans[4] = {ADC_CH_PIEZO, ADC_CH_VBAT, ADC_CH_PIEZO, ADC_CH_VBUS};
    for (int i = 0; i < 4; ++i) {
        pattern[i].atten = ADC_ATTEN_DB_11;     // ~0..3.1 V
        pattern[i].channel = chans[i];
        pattern[i].unit = 0;                    // pattern unit index: 0 = ADC1
        pattern[i].bit_width = SOC_ADC_DIGI_MAX_BITWIDTH;
    }
    adc_digi_configuration_t cfg = {};
    cfg.conv_limit_en = false;
    cfg.conv_limit_num = 250;
    cfg.pattern_num = 4;
    cfg.adc_pattern = pattern;
    cfg.sample_freq_hz = kConvRate;
    cfg.conv_mode = ADC_CONV_SINGLE_UNIT_1;
    cfg.format = ADC_DIGI_OUTPUT_FORMAT_TYPE2;
    if (adc_digi_controller_configure(&cfg) != ESP_OK) return false;
    esp_adc_cal_characterize(ADC_UNIT_1, ADC_ATTEN_DB_11, ADC_WIDTH_BIT_12, 1100, &adc_chars);
    return adc_digi_start() == ESP_OK;
}

static void pushPiezo(float raw) {
    // Band-limit to the trombone range: 35 Hz .. 2 kHz, 4th order each side.
    float x = lp2.process(lp1.process(hp2.process(hp1.process(raw))));
    ring[ring_pos] = x;
    ring_pos = (ring_pos + 1) % kRing;
    if (filled < kRing) ++filled;
    ++since_hop;
}

static void estimate() {
    size_t need = yin->requiredSamples();
    if (filled < need) return;
    // unroll the most recent `need` samples, oldest first
    size_t start = (ring_pos + kRing - need) % kRing;
    double sumsq = 0;
    for (size_t i = 0; i < need; ++i) {
        float v = ring[(start + i) % kRing];
        frame[i] = v;
        sumsq += v * v;
    }
    Pitch p;
    p.rms = sqrtf((float)(sumsq / need));
    p.at_ms = millis();
    if (p.rms >= kMinRms) {
        uint32_t t0 = micros();
        p.hz = yin->detect(frame, &p.confidence);
        yin_us = micros() - t0;
    }
    portENTER_CRITICAL(&mux);
    shared = p;
    portEXIT_CRITICAL(&mux);
    ++frames;
}

static void task(void*) {
    static uint8_t buf[kDmaFrameBytes];
    float vbat_acc = 0, vbus_acc = 0;
    uint32_t vbat_n = 0, vbus_n = 0;
    for (;;) {
        uint32_t got = 0;
        esp_err_t err = adc_digi_read_bytes(buf, sizeof buf, &got, 100);
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) continue;  // INVALID_STATE = overrun, data still usable
        for (uint32_t i = 0; i + SOC_ADC_DIGI_RESULT_BYTES <= got; i += SOC_ADC_DIGI_RESULT_BYTES) {
            const adc_digi_output_data_t* d = (const adc_digi_output_data_t*)&buf[i];
            uint32_t ch = d->type2.channel, raw = d->type2.data;
            if (ch == ADC_CH_PIEZO) {
                pushPiezo((float)raw);
                if (since_hop >= kHop) {
                    since_hop = 0;
                    estimate();
                }
            } else if (ch == ADC_CH_VBAT) {
                vbat_acc += raw;
                ++vbat_n;
            } else if (ch == ADC_CH_VBUS) {
                vbus_acc += raw;
                ++vbus_n;
            }
        }
        if (vbat_n >= 4000) {  // ~0.5 s of supply samples
            float vb = 2.0f * esp_adc_cal_raw_to_voltage((uint32_t)(vbat_acc / vbat_n), &adc_chars) / 1000.0f;
            float vu = vbus_n ? 2.0f * esp_adc_cal_raw_to_voltage((uint32_t)(vbus_acc / vbus_n), &adc_chars) / 1000.0f : 0;
            portENTER_CRITICAL(&mux);
            vbat = vb;
            vbus = vu;
            portEXIT_CRITICAL(&mux);
            vbat_acc = vbus_acc = 0;
            vbat_n = vbus_n = 0;
        }
    }
}

bool begin() {
    hp1 = Biquad::highpass(kPiezoRate, 35.0f);
    hp2 = Biquad::highpass(kPiezoRate, 35.0f);
    lp1 = Biquad::lowpass(kPiezoRate, 2000.0f);
    lp2 = Biquad::lowpass(kPiezoRate, 2000.0f);
    yin = new Yin(kPiezoRate, kWindow);
    if (yin->requiredSamples() > kRing) return false;
    if (!startAdc()) return false;
    // Core 0 alongside the NimBLE host; priority below BLE, above idle.
    return xTaskCreatePinnedToCore(task, "audio", 6144, nullptr, 3, nullptr, 0) == pdPASS;
}

Pitch latest() {
    portENTER_CRITICAL(&mux);
    Pitch p = shared;
    portEXIT_CRITICAL(&mux);
    return p;
}

float batteryVolts() {
    portENTER_CRITICAL(&mux);
    float v = vbat;
    portEXIT_CRITICAL(&mux);
    return v;
}

float usbVolts() {
    portENTER_CRITICAL(&mux);
    float v = vbus;
    portEXIT_CRITICAL(&mux);
    return v;
}

uint32_t framesProcessed() { return frames; }
uint32_t lastYinMicros() { return yin_us; }

}  // namespace audio
