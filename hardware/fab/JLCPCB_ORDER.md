# JLCPCB Order Instructions — SlidePod rev 0.2

Place the order at https://jlcpcb.com. All files needed are in this directory (`hardware/fab/`).
Regenerate them after any board change: `make fab` (from `hardware/`).

> **Cost reference:** the only real quote so far is rev 0.1 (2026-11-07, qty 5, top-side assembly
> only): $161.86 before shipping (PCB $8.00, parts $62.67, feeder loading $44.95, setup $25.75,
> stencil $8.27, X-ray $8.25, other $3.97). Rev 0.2 is assembled on **both sides**, which adds a
> second setup and stencil, plus the IMU — expect noticeably more. Record the new quote here.

---

## Step 1 — Upload Gerbers

1. Go to https://jlcpcb.com and click **Quote Now**.
2. Upload `slidepod-gerbers.zip`.
3. Wait for the board preview: it should show a **32 × 26 mm** board, 4 layers.

## Step 2 — PCB options

Set **exactly** these values (others can stay at default):

| Option | Value |
|---|---|
| Layers | 4 |
| PCB Thickness | **1.0 mm** (default is 1.6 — must change this; the mount is sized for 1.0) |
| Surface Finish | HASL(with lead) |
| Quantity | 5 |
| Different Design | 1 |

Leave impedance control, blind/buried vias, castellated holes all off/no.
Vias are 0.45/0.2 mm, which is within the standard 4-layer process (no extra charge).

## Step 3 — Enable PCB Assembly

Toggle **PCB Assembly** on (right side of the page).

| Option | Value |
|---|---|
| **PCBA Type** | **Standard** (not Economic — U1, U2 and U7 require Standard) |
| **Assembly Side** | **Both Sides** (rev 0.2 has parts on the back — see below) |
| PCBA Qty | 5 |
| Tooling Holes | Added by JLCPCB |
| Confirm Parts Placement | Yes (auto-confirms after 72 h if no response) |

> The board also carries its own three 1.0 mm NPTH tooling holes (TH1–TH3, in the corners).
> Standard PCBA adds edge rails to a board this small anyway; the extra holes do no harm.

Which side each part is on (from `slidepod-cpl.csv`):

- **Top (11):** U1 (ESP32-S3), U2 (ToF), U7 (IMU), J1 (USB-C), SW3, LED1–LED3, D3, C17, C18.
- **Bottom (38):** U3, U4, U6, Q1, D2, J2 (battery), and the rest of the resistors and capacitors.

Click **Confirm** to proceed to the assembly step.

## Step 4 — Upload BOM and CPL

When prompted:
- BOM file: `slidepod-bom.csv` (26 lines, 49 placements)
- CPL file: `slidepod-cpl.csv`

Click **Process BOM & CPL**.

## Step 5 — Verify parts

JLCPCB will show a parts table. Check each row:

| LCSC | Part | Ref | Side | Expected status |
|---|---|---|---|---|
| C2913206 | ESP32-S3-MINI-1-N8 | U1 | Top | Extended |
| C190004 | VL53L1CXV0FY/1 | U2 | Top | Confirm available |
| C967633 | LSM6DS3TR-C (IMU, new in rev 0.2) | U7 | Top | Confirm available |
| C424093 | MCP73831T-2ACI/OT | U3 | Bottom | Confirm available |
| C82942 | ME6211C33M5G-N | U4 | Bottom | Extended |
| C7519 | USBLC6-2SC6 | U6 | Bottom | Extended |
| C165948 | TYPE-C-31-M-12 (USB-C) | J1 | Top | Extended |
| C160402 | JST SH SM02B-SRSS-TB (battery, new in rev 0.2) | J2 | Bottom | Confirm available |
| C431540 | MSK12C02 (power switch) | SW3 | Top | Confirm available |
| C15127 | AO3401A | Q1 | Bottom | Basic |
| C8598 | B5819W | D2 | Bottom | Basic |
| C2286 | KT-0603R red LED | D3, LED1 | Top | Basic |
| C12624 | KT-0603G green LED | LED2 | Top | Extended |
| C2288 | KT-0603B blue LED | LED3 | Top | Extended |

Passives (resistors, capacitors) are all Basic and will auto-match. New in rev 0.2: R19/R20
(4.7k, the IMU bus pull-ups) share a line with R15/R16.

If any part shows "Shortfall" or "No stock", note it — accept the order and
hand-solder that part, or find an alternative LCSC number.

## Step 6 — Placement preview and rotation/position check

After confirming parts, JLCPCB shows each component placed on the board, one side at a time.
**Check both sides.** Rotations and positions are pre-corrected in `export_jlc.py`, but those
corrections were measured on rev 0.1, which had every part on the top.

### Top side — corrections already applied, still verify

| Ref | Package | LCSC | CPL rot | Correction |
|---|---|---|---|---|
| U2 | LGA-12 (VL53L1CX) | C190004 | 180 | rotation +180 |
| U1 | ESP32-S3-MINI-1 | C2913206 | 0 | position Y −2.5 mm (model origin toward the antenna) |
| J1 | TYPE-C-31-M-12 | C165948 | 90 | position X −1.1 mm (pins toward the mouth) |

J1's position offset turns with the part (`xy_offset` in `export_jlc.py`). On rev 0.1 the mouth
faced −X and the shift was +1.1 mm; on rev 0.2 it faces the right edge (+X), so the shift is
−1.1 mm. Check that J1's signal pins sit on their pads and the shell legs on the slots.

U7 (LSM6DS3TR-C) has no correction yet: check its pin-1 dot against the footprint's pin 1.

### Bottom side — unverified, check every part

These rotation offsets were measured on the **top** side of rev 0.1. On the bottom the view is
mirrored, so a part can come out turned 180° (or ±90°). Check pin 1 of each one:

| Ref | Package | LCSC | CPL rot | Offset in `export_jlc.py` |
|---|---|---|---|---|
| U3 | SOT-23-5 (MCP73831) | C424093 | 270 | +270 |
| U4 | SOT-23-5 (ME6211) | C82942 | 270 | +270 |
| U6 | SOT-23-6 (USBLC6) | C7519 | 270 | +270 |
| Q1 | SOT-23 (AO3401A) | C15127 | 90 | +90 |
| D2 | SOD-123 (B5819W) | C8598 | 270 | none — check the cathode bar |
| J2 | JST SH 2-pin | C160402 | 0 | none — check the connector opening faces the board edge |

If a part is wrong, fix it in the preview UI, and **write down the correction** so it can go into
`export_jlc.py` (bottom-side offsets may need their own table, keyed on side).

> The sign convention for rotations is CCW-positive (JLCPCB convention).
> CPL Y is negated relative to KiCad board coordinates.

## Step 7 — Customs description

When prompted for a customs description, use:
**Research/Education/DIY/Entertainment → DIY Hobby Circuit Board**

## Step 8 — Quote and order

Review the price, then proceed through shipping and payment. Record the quote breakdown at the top
of this file.

---

## Notes

- **Test points** (TP1–TP9) are not in the BOM — probe points and recovery pads. Correct.
- **No BOOT/RESET buttons on rev 0.2.** Flash over native USB. For recovery, short the BOOT test
  pad (or EN) to the GND pad next to it on the back.
- **U1 footprint:** U1 (ESP32-S3-MINI-1-N8) uses the KiCad `RF_Module:ESP32-S2-MINI-1`
  footprint (same outline and pad numbering). The S3 GPIO-to-pad mapping is in
  `tools/circuit.py`; `python tools/check_pins.py` checks the firmware's rev 0.2 pins against the
  routed board.
- **Firmware for rev 0.2:** `pio run -e slidepod-rev2 -t upload` (rev 0.2 pin map).
- **JST-SH battery polarity** is not standardised across vendors. When the battery arrives,
  verify the `+` lead against the `+` marking on the board before connecting.
- **VL53L1X aperture:** the enclosure must have an open window or IR-transparent
  cover in front of U2. See ST AN4907 for cover-window spacing rules.
- **Known DRC leftovers (not blockers):** two of the NPTH tooling holes sit inside the U1 antenna
  keepout (no copper, no RF effect), a few single-spoke thermal reliefs on GND pads, and silkscreen
  clipped by the board edge and mask.
