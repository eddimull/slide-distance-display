# SlidePod rev 0.2 Wokwi simulation.
#   make            build the VL53L1X chip (wasm) and the firmware
#   make test       native unit test of the chip emulation (no Wokwi needed)
#   make sim        run headless in Wokwi with the serial monitor (needs wokwi-cli + WOKWI_CLI_TOKEN)
#   make test-sim   run scenario.yaml in Wokwi and check the firmware's output

ROOT     := ../..
PIO      ?= $(HOME)/.platformio/penv/bin/pio
WASM_LD  ?= $(shell command -v wasm-ld 2>/dev/null || command -v wasm-ld-18 2>/dev/null || echo /usr/lib/llvm-18/bin/wasm-ld)
CHIP     := chips/vl53l1x.chip.wasm
BUILD    := build

# wokwi-cli token: $WOKWI_CLI_TOKEN, else ~/.config/wokwi/token (never commit it)
WOKWI_CLI_TOKEN ?= $(shell cat $(HOME)/.config/wokwi/token 2>/dev/null)
export WOKWI_CLI_TOKEN

CHIP_FLAGS := --target=wasm32-unknown-wasi -O2 -ffreestanding -nostdlib -fuse-ld=$(WASM_LD) \
              -Wl,--export-table -Wl,--no-entry -Wl,--import-memory -Wl,--allow-undefined \
              -Wall -Werror -Wno-unused-function

all: $(CHIP) firmware

$(CHIP): chips/vl53l1x.chip.c chips/wokwi-api.h
	clang $(CHIP_FLAGS) -o $@ $<

firmware:
	cd $(ROOT) && $(PIO) run -e slidepod-wokwi

test:
	mkdir -p $(BUILD)
	cc -std=c11 -Wall -Wno-unused-function -Wno-attributes -Wno-unknown-attributes -fno-builtin \
	   -o $(BUILD)/test_vl53l1x chips/test_vl53l1x.c 2>/dev/null || \
	cc -std=c11 -w -fno-builtin -o $(BUILD)/test_vl53l1x chips/test_vl53l1x.c
	$(BUILD)/test_vl53l1x

sim: all
	wokwi-cli . --timeout 60000 --interactive

test-sim: all
	wokwi-cli . --timeout 30000 --scenario scenario.yaml

clean:
	rm -rf $(BUILD) $(CHIP)

.PHONY: all firmware test sim test-sim clean
