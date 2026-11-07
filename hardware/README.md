# SlidePod: wireless trombone slide sensor

A single clip-on pod for the stationary inner slide. It measures slide extension with a
VL53L1X time-of-flight sensor and pitch with a piezo contact pickup. It sends position,
pitch and partial over BLE to the Flutter app. There is no screen and no wire to the bell.

## Mechanical constraint that shapes the board

The VL53L1X emits **perpendicular to the PCB**. For the beam to run down the slide, the
board stands as a thin "fin" perpendicular to the slide tubes:

```
        side view (slide runs left → right)

            ┌──┐  ← antenna end (top, away from brass)
            │  │
     PCB →  │  │──►  ToF beam toward the reflector tab on the outer handle brace
   (fin)    │  │
            │▓▓│  ← battery behind the board
     ═══════╧══╧═════════ inner slide tube (clamp + piezo at bottom)
```

- The ToF sits on the **front face** with nothing taller than it nearby. The ESP32 module,
  USB-C, switch and battery connector go on the back or sides.
- The module antenna sits at the top edge, as far from the brass as possible, with copper
  keep-out on all layers under and around it per the Espressif guidelines.
- The piezo disc is in the clamp and connects to two pads at the bottom edge.

Current outline: **30 × 50 mm**, 4-layer, 1.0 mm thick, single-sided assembly. It can shrink later by moving parts to the back side, but JLC charges more for double-sided assembly.

## Block diagram

```
USB-C ─ESD─┬─ D+/D- ──────────────────────────────► ESP32-S3 GPIO19/20 (native USB)
           └─ VBUS ─┬─► MCP73831 ──► VBAT ─┐
                    │                       ├─(power path)─► SW ─► VSYS ─► ME6211 ─► 3V3
                    └──────── Schottky ─────┘   P-FET from VBAT, gated by VBUS
JST-PH (1S LiPo with protection PCB) ─► VBAT

3V3 ─► ESP32-S3-MINI-1, VL53L1X, MCP6001, status LEDs
```

## Pin map (ESP32-S3-MINI-1)

| Net | GPIO | Notes |
|---|---|---|
| PIEZO_ADC | 1 | ADC1_CH0, continuous/DMA mode at 8–16 kHz |
| VBAT_SENSE | 2 | ADC1_CH1, 1M/1M divider from VBAT + 100 nF (about 2 µA drain) |
| TOF_INT | 4 | VL53L1X GPIO1 (open-drain, 10k pull-up) |
| TOF_XSHUT | 5 | 10k pull-up; drive low to power the sensor down |
| I2C_SDA | 8 | 4.7k pull-up |
| I2C_SCL | 9 | 4.7k pull-up |
| VBUS_SENSE | 10 | 100k/100k divider from VBUS (5 V → 2.5 V): USB present |
| LED_R / LED_G / LED_B | 11 / 12 / 13 | Three 0603 LEDs, anodes to 3V3, active-low, LEDC PWM |
| USB_D- / USB_D+ | 19 / 20 | Built-in USB-Serial/JTAG for flashing and logs |
| BOOT | 0 | Tactile switch to GND, 10k pull-up |
| EN | EN | 10k pull-up + 1 µF to GND, RESET switch to GND |
| U0TXD / U0RXD | 43 / 44 | Test pads only |

Avoided: strapping pins 3, 45, 46, and ADC2, which conflicts with the radio.

**Why discrete LEDs and not a WS2812:** the system runs at 3.3 V, below the WS2812's
rated supply. A WS2812 also draws about 1 mA even when off, while discrete LEDs on LEDC
draw nothing.

## Circuit blocks

### Power
- **USB-C receptacle (16-pin):** CC1 and CC2 each get 5.1k to GND (UFP, 5 V default).
  USBLC6-2SC6 on D+/D-/VBUS.
- **MCP73831T-2ACI/OT charger:** 4.2 V. R_PROG = 3.3k sets I_chg = 1000 V / 3.3 kΩ ≈ 300 mA
  (about 0.75C for a 400 mAh cell). 4.7 µF on VBUS and on VBAT.
- **Power path:** a Schottky diode from VBUS feeds VSYS. A P-MOSFET (gate to VBUS, 100k
  gate pull-down) connects VBAT to VSYS when USB is absent. This way the charger never
  sees the system load.
- **Power switch:** an SMD slide switch in series with VSYS. The battery still charges with the switch off.
- **Charge LED:** an orange LED on MCP73831 STAT (lit while charging). STAT is not wired to the ESP32, so an unpowered ESP32 is never back-fed through it.
- **ME6211C33 LDO:** 500 mA, enough for ESP32-S3 radio peaks of about 350 mA. 10 µF in and 10 µF out.
- **Battery:** 1S LiPo, 300–500 mAh, **with a protection PCB** (this board doesn't add protection).

### ESP32-S3-MINI-1
- 3V3 on all supply pins, with 10 µF + 100 nF near the module, plus 100 nF at each supply pin group.
- All GND pads go to a solid ground plane on layer 2, stitched with vias.

### VL53L1X
- AVDD and AVDDVCSEL to 3V3, each with 100 nF, plus 4.7 µF bulk.
- I2C address 0x29. XSHUT and GPIO1 as in the pin map.
- Enclosure: an open aperture in front of the sensor, or an IR-transparent cover window
  spaced per ST AN4907. Run crosstalk calibration in firmware if there's a cover.

### Piezo front end (MCP6001)
```
3V3 ─100k─┬─100k─ GND          Vb = mid-rail, 10 µF to GND
          Vb
          │
         1M 
          │
PIEZO+ ──┼──1k──► (+) MCP6001 ──┬── out ──1k──┬──► PIEZO_ADC (GPIO1)
PIEZO- ──GND  BAT54S to 3V3/GND  │              10 nF
                          (−) ─┬─ Rf 100k (DNP-able 47k option)
                               Rg 10k ── 1 µF ── Vb
```
- Gain is about 11, and there are footprints for a second Rf value because gain is the main unknown.
- The high-pass corner (10 MΩ with the piezo's C) is well under 40 Hz. Real band-limiting
  (about 35 Hz to 2 kHz) happens in firmware.
- The 1k/10 nF RC is the anti-alias filter (fc ≈ 16 kHz) and isolates the ADC sampling cap.

### Indicator and controls
- Three separate 0603 LEDs (red, green, blue), side by side for a light pipe. Series resistors: 1k red (about 1.3 mA), 33 Ω green and blue (about 3–9 mA, depending on Vf at 3.3 V). Balance brightness with PWM in firmware.
  A combined RGB package was dropped because no JLC common-anode part had a pinout I could verify.
- BOOT and RESET tactile switches on the board edge, which the enclosure can expose as pinholes.

### Test points
3V3, VSYS, VBAT, GND, PIEZO_ADC, U0TXD, U0RXD.

## Key parts (JLCPCB / LCSC)

Check live stock and the Basic/Extended label on jlcpcb.com/partdetail/<C#> before ordering.

| Ref | Part | LCSC | Status |
|---|---|---|---|
| U1 | ESP32-S3-MINI-1-N8 | C2913206 | Extended. Alternate: N4R2 C3013941 (PSRAM, not needed) |
| U2 | VL53L1CXV0FY/1 | C190004 | Not yet confirmed on JLC |
| U3 | MCP73831T-2ACI/OT | C424093 | Not yet confirmed |
| U4 | ME6211C33M5G-N | C82942 | Extended. Alternate: AP2112K-3.3 C51118 |
| U5 | MCP6001T-I/OT | C116490 | Not yet confirmed |
| U6 | USBLC6-2SC6 (ST) | C7519 | Extended |
| J1 | TYPE-C-31-M-12 | C165948 | Extended |
| J2 | JST S2B-PH-SM4-TB | C295747 | Extended |
| D1 | BAT54S (Nexperia) | C47546 | Extended (no Basic BAT54S exists) |
| SW1/2 | TS-1187A-B-A-B | C318884 | Not yet confirmed |
| SW3 | MSK12C02 | C431540 | Not yet confirmed |
| Q1 | AO3401A | C15127 | Basic |
| D2 | B5819W (CJ) | C8598 | Basic |
| LED1, D3 | KT-0603R red | C2286 | Basic |
| LED2 / LED3 | 0603 green / blue | TBD | Pick Basic parts in the JLC library |
| R, C | 0402 resistors and capacitors (4.7 µF and 10 µF are 0603) | see `LCSC_R0402` / `LCSC_C` in `tools/circuit.py` | Basic |

## Firmware-facing summary
- I2C @ 400 kHz on GPIO8/9. VL53L1X in Short mode, 20 ms budget, 8×8 ROI.
- Piezo on ADC1_CH0, continuous mode.
- BLE GATT notify at 50 Hz with about 10 bytes per update. Calibration (offset, length) goes in a writable characteristic.

## Design files and workflow

The schematic and board are **generated** from Python, so changes are reviewable as code:

| File | Role |
|---|---|
| `tools/circuit.py` | **Source of truth:** parts, values, footprints, LCSC numbers, pin-to-net map |
| `tools/gen_sch.py` | Builds `slidepod.kicad_sch` (a net label on every pin, using KiCad library symbols) |
| `tools/gen_pcb.py` | Builds `slidepod.kicad_pcb`: outline, 4-layer stackup, net classes, placement, GND pours |
| `tools/check_net.py` | Checks the exported netlist against `circuit.py`, pin by pin |
| `tools/kicad.sh` | Runs any command in the `kicad/kicad:9.0` Docker image (no local install needed) |

```sh
make            # ERC, netlist check against circuit.py, DRC with schematic parity
make pcb        # re-place the board (DISCARDS routing; use only before routing)
make route      # fan-out, Freerouting, finish, stitch (about 30 min)
make fab        # Gerbers, drill, BOM, CPL into fab/
make pdf        # schematic PDF
```

**Placement:** anchor parts (module, ToF, connectors, buttons, LED) have fixed positions
in `ANCHORS`. Everything else is packed to the nearest free spot beside the pins it
connects to. Parts excluded from placement:

- the antenna band (top 6.6 mm), via the module's keep-out rule area
- a 6 × 3.8 mm window around the VL53L1X

### Status (rev 0.1)
- [x] Schematic: ERC clean, netlist matches `circuit.py` (233 pins)
- [x] Board: 30 × 50 mm, 4 layers. Placement, routing, GND/+3V3 planes, stitching.
      **DRC: 0 errors, 0 unconnected, schematic parity clean.**
- [x] Fab outputs in `fab/`: `slidepod-gerbers.zip` (Gerbers + drill), `slidepod-bom.csv`, `slidepod-cpl.csv`
- [ ] Pick JLC Basic green (LED2) and blue (LED3) 0603 LEDs; add them to `circuit.py`, then `make fab`
- [ ] Recheck the MCP6001, VL53L1X, MCP73831 and switches on JLC
- [ ] In JLC's assembly preview, check every part's rotation (CPL rotations follow KiCad's zero orientation)

### Stackup and routing pipeline (`make route`)

| Layer | Use |
|---|---|
| F.Cu | Signals + GND pour |
| In1.Cu | Solid GND plane |
| In2.Cu | +3V3 plane |
| B.Cu | Signals + GND pour |

1. `stitch.py fanout`: every +3V3 and GND pad gets a via to its plane plus a short stub, all locked.
2. Freerouting (headless, `.tools/freerouting.jar`) routes the signal nets. GND is excluded.
3. `route.py import` brings the routes back into KiCad.
4. `finish_route.py`: a small grid A* router connects whatever Freerouting left open.
5. `stitch.py finish` removes dangling stubs, adds a 3 mm grid of GND stitching vias, and refills the pours.

`move_part.py REF TARGET PAD` moves one part on the routed board and re-routes its nets
with `finish_route.py`. Rev 0.1 used it once: R6 went next to R7 and C5, so the whole
battery-sense divider sits at the ADC pin. `gen_pcb.py` now places it there itself.

### Review before ordering
- The piezo amplifier gain (R23, with R24 left unfitted) is a guess. Test it on a real horn.
- The JST-PH battery polarity isn't standard across vendors. Check the battery leads against the `+` marking.
- The VL53L1X needs an open aperture or a proper cover window in the enclosure (ST AN4907).
- Check BLE range with the pod clamped on the horn. Brass near the antenna detunes it.
- A few F.Cu traces run under the ESP32 module, between its center GND pads (solder mask covers them). Espressif allows this outside the antenna area, but rerouting them would remove any risk of shorts.
