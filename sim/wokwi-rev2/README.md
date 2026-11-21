# SlidePod rev 0.2 in Wokwi

This sim models the rev 0.2 board's circuit and runs the **real-hardware firmware**: the rev 0.2
pin map and the Pololu VL53L1X driver, not the `WOKWI_SIM` mock. The ToF sensor is a register-level
VL53L1X emulator written as a Wokwi custom chip.

| Board net | rev 0.2 pin | In the sim |
|---|---|---|
| TOF_SDA / TOF_SCL | IO38 / IO39 | `chip-vl53l1x` (I2C 0x29) with 4.7k pull-ups R15/R16 |
| TOF_XSHUT / TOF_INT | IO36 / IO37 | XSHUT and GPIO1 on the chip, 10k pull-ups R17/R18 |
| LED_R / LED_G / LED_B | IO42 / IO41 / IO40 | Active-low LEDs to 3V3 through R12 1k / R13 33Ω / R14 33Ω |
| BOOT | IO0 | Push button (stands in for the TP9 pad), 10k pull-up R11 |
| Serial | UART0 | Wokwi serial monitor (the `slidepod-wokwi` build sets `ARDUINO_USB_CDC_ON_BOOT=0`) |

Not simulated:
- the LSM6DS3TR-C IMU (no Wokwi part, and the firmware doesn't use it yet)
- the battery and USB sense dividers (not read by the firmware)
- the charger and power path
- BLE (Wokwi doesn't simulate the S3's radio, so the build sets `SLIDEPOD_NO_BLE`)

## The VL53L1X chip (`chips/vl53l1x.chip.c`)

The chip emulates:
- the ID, boot status and oscillator calibration registers
- soft reset
- timed and single-shot ranging at the period the driver programs
- the 17-byte result block
- data-ready / interrupt-clear, and the GPIO1 interrupt line
- XSHUT

On the chip you can set **Distance**, **Noise (± mm)** and **Max range**. Beyond max range the
chip reports a signal failure, the same as losing the slide brace. The chip doesn't model ROI
geometry or signal strength.

## Run it

```sh
make          # chip -> chips/vl53l1x.chip.wasm (clang wasm32, no libc) + firmware (pio env slidepod-wokwi)
make test     # native test of the chip against the driver's register traffic
```

Then either:

- **VS Code:** install the Wokwi extension, run *Wokwi: Select Config File*, pick
  `sim/wokwi-rev2/wokwi.toml`, then *Wokwi: Start Simulator*. Click the VL53L1X to drag its distance.
- **CLI:** install [wokwi-cli](https://github.com/wokwi/wokwi-cli) and get a CI token from
  https://wokwi.com/dashboard/ci (`export WOKWI_CLI_TOKEN=...`). Then:
  - `make sim` runs it with the serial monitor.
  - `make test-sim` runs `scenario.yaml`, which drives the distance through 1st, mid-slide,
    the Medium-mode switch past 500 mm, losing the target, and back. It checks the firmware's
    CSV and mode messages.
