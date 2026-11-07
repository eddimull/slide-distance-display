#include "ble_link.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <string.h>

namespace ble_link {

using namespace slidepod;

static NimBLEServer* server = nullptr;
static NimBLECharacteristic* state_chr = nullptr;
static NimBLECharacteristic* cal_chr = nullptr;
static volatile bool is_connected = false;

static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
static Pending pending;
static bool has_pending = false;

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* s, ble_gap_conn_desc* desc) override {
        is_connected = true;
        // 7.5-15 ms interval so 50 Hz notifications flow without bunching.
        s->updateConnParams(desc->conn_handle, 6, 12, 0, 200);
    }
    void onDisconnect(NimBLEServer*) override {
        is_connected = server && server->getConnectedCount() > 0;
        // NimBLE restarts advertising on disconnect by default.
    }
};

class CalibrationCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c) override {
        std::string v = c->getValue();
        SlideCalibration cal;
        if (!decodeCalibration((const uint8_t*)v.data(), v.size(), &cal)) return;
        portENTER_CRITICAL(&mux);
        pending.calibration_written = true;
        pending.calibration = cal;
        has_pending = true;
        portEXIT_CRITICAL(&mux);
    }
};

class ControlCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c) override {
        std::string v = c->getValue();
        if (v.empty()) return;
        portENTER_CRITICAL(&mux);
        pending.control = true;
        pending.control_len = v.size() < sizeof pending.control_bytes ? v.size() : sizeof pending.control_bytes;
        memcpy(pending.control_bytes, v.data(), pending.control_len);
        has_pending = true;
        portEXIT_CRITICAL(&mux);
    }
};

void begin(const char* name) {
    NimBLEDevice::init(name);
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
    server = NimBLEDevice::createServer();
    server->setCallbacks(new ServerCallbacks());

    NimBLEService* svc = server->createService(SLIDEPOD_SERVICE_UUID);
    state_chr = svc->createCharacteristic(SLIDEPOD_STATE_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    cal_chr = svc->createCharacteristic(SLIDEPOD_CALIBRATION_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE);
    cal_chr->setCallbacks(new CalibrationCallbacks());
    NimBLECharacteristic* ctrl = svc->createCharacteristic(SLIDEPOD_CONTROL_UUID, NIMBLE_PROPERTY::WRITE);
    ctrl->setCallbacks(new ControlCallbacks());
    svc->start();

    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(SLIDEPOD_SERVICE_UUID);
    adv->setScanResponse(true);
    adv->start();
}

bool connected() { return is_connected; }

void notifyState(const State& s) {
    if (!state_chr) return;
    uint8_t buf[kStatePacketSize];
    size_t n = encodeState(s, buf);
    state_chr->setValue(buf, n);
    if (is_connected) state_chr->notify();
}

void setCalibration(const SlideCalibration& cal) {
    if (!cal_chr) return;
    uint8_t buf[kCalibrationPacketSize];
    size_t n = encodeCalibration(cal, buf);
    cal_chr->setValue(buf, n);
}

bool takePending(Pending& out) {
    portENTER_CRITICAL(&mux);
    bool any = has_pending;
    if (any) {
        out = pending;
        pending = Pending();
        has_pending = false;
    }
    portEXIT_CRITICAL(&mux);
    return any;
}

}  // namespace ble_link
