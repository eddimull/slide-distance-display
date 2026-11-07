# JLCPCB Order Instructions — SlidePod rev 0.1

Place the order at https://jlcpcb.com. All files needed are in this directory (`hardware/fab/`).

> **Cost reference (first order, 2026-11-07, qty 5 assembled):** $161.86 before shipping.
> Breakdown: PCB $8.00, parts $62.67, feeder loading $44.95, setup $25.75,
> stencil $8.27, X-ray $8.25, other $3.97.

---

## Step 1 — Upload Gerbers

1. Go to https://jlcpcb.com and click **Quote Now**.
2. Upload `slidepod-gerbers.zip`.
3. Wait for the board preview to appear (should show a 30 × 50 mm board).

## Step 2 — PCB options

Set **exactly** these values (others can stay at default):

| Option | Value |
|---|---|
| Layers | 4 |
| PCB Thickness | **1.0 mm** (default is 1.6 — must change this) |
| Surface Finish | HASL(with lead) |
| Quantity | 5 |
| Different Design | 1 |

Leave impedance control, blind/buried vias, castellated holes all off/no.

## Step 3 — Enable PCB Assembly

Toggle **PCB Assembly** on (right side of the page).

| Option | Value |
|---|---|
| **PCBA Type** | **Standard** (not Economic — U1 and U2 require Standard) |
| Assembly Side | Top |
| PCBA Qty | 5 |
| Tooling Holes | Added by JLCPCB |
| Confirm Parts Placement | Yes (auto-confirms after 72 h if no response) |

> Note: Standard PCBA adds edge rails (board treated as 70 × 70 mm), a stencil,
> X-ray inspection, and per-part feeder fees. This is unavoidable for the ESP32
> module (C2913206) and VL53L1CX (C190004).

Click **Confirm** to proceed to the assembly step.

## Step 4 — Upload BOM and CPL

When prompted:
- BOM file: `slidepod-bom.csv`
- CPL file: `slidepod-cpl.csv`

Click **Process BOM & CPL**.

## Step 5 — Verify parts

JLCPCB will show a parts table. Check each row:

| LCSC | Part | Expected status |
|---|---|---|
| C2913206 | ESP32-S3-MINI-1-N8 | Extended |
| C190004 | VL53L1CXV0FY/1 | Confirm available |
| C424093 | MCP73831T-2ACI/OT | Confirm available |
| C82942 | ME6211C33M5G-N | Extended |
| C116490 | MCP6001T-I/OT | Confirm available |
| C7519 | USBLC6-2SC6 | Extended |
| C165948 | TYPE-C-31-M-12 (USB-C) | Extended |
| C295747 | JST S2B-PH-SM4-TB | Extended |
| C47546 | BAT54S | Extended |
| C318884 | TS-1187A-B-A-B (SW1,SW2) | Confirm available |
| C431540 | MSK12C02 (SW3) | Confirm available |
| C15127 | AO3401A | Basic |
| C8598 | B5819W | Basic |
| C2286 | KT-0603R red LED (D3,LED1) | Basic |
| C12624 | KT-0603G green LED | Extended |
| C2288 | KT-0603B blue LED | Extended |

Passives (resistors, capacitors) are all Basic and will auto-match.

If any part shows "Shortfall" or "No stock", note it — accept the order and
hand-solder that part, or find an alternative LCSC number.

## Step 6 — Placement preview and rotation/position check

After confirming parts, JLCPCB shows each component placed on the board.
Rotations and positions have been pre-corrected in `export_jlc.py` based on
the first order, but **verify every part in the preview anyway** in case JLCPCB
has updated their part models.

### Rotation corrections (already applied in CPL)

| Ref | Package | LCSC | CPL rot | JLCPCB rot | Offset |
|---|---|---|---|---|---|
| D1 | SOT-23 (BAT54S) | C47546 | 90 | 180 | +90 |
| Q1 | SOT-23 (AO3401A) | C15127 | 90 | 180 | +90 |
| U3 | SOT-23-5 (MCP73831) | C424093 | 0 | 270 | +270 (90° CW) |
| U4 | SOT-23-5 (ME6211) | C82942 | 0 | 270 | +270 (90° CW) |
| U6 | SOT-23-6 (USBLC6) | C7519 | 0 | 270 | +270 (90° CW) |
| U5 | SOT-23-5 (MCP6001) | C116490 | 0 | 180 | +180 |
| U2 | LGA-12 (VL53L1CX) | C190004 | 0 | 180 | +180 |

No rotation change needed for: D2, D3, LED1–3, J2, SW1, SW2, SW3.

### Position corrections (already applied in CPL)

| Ref | Problem | Offset applied |
|---|---|---|
| U1 | Model shifted toward antenna end (antenna past board edge) | Y −2.5 mm |
| J1 | Signal pins sat ~1.1 mm short of pads toward the mouth | X +1.1 mm |

> The sign convention for rotations is CCW-positive (JLCPCB convention).
> CPL Y is negated relative to KiCad board coordinates.
> If any part looks wrong in the preview, correct it in the UI before proceeding.

## Step 7 — Customs description

When prompted for a customs description, use:
**Research/Education/DIY/Entertainment → DIY Hobby Circuit Board**

## Step 8 — Quote and order

Review the price, then proceed through shipping and payment.

---

## Notes

- **R24 is DNP** (do not place) — not in the BOM or CPL. Correct.
- **J3 (piezo pads) and test points** are not in the BOM — hand-soldered or probe points. Correct.
- **U1 footprint warning:** U1 (ESP32-S3-MINI-1-N8) is placed on the KiCad
  `RF_Module:ESP32-S2-MINI-1` footprint. The S2-MINI-1 and S3-MINI-1 share the
  same outline and pad layout, but have different pin functions. Verify that
  `tools/circuit.py` maps S3 GPIO numbers to the correct pad numbers before
  powering up the first board.
- **JST-PH battery polarity** is not standardised across vendors. When the
  battery arrives, verify the `+` lead against the `+` marking on the board
  before connecting.
- **VL53L1X aperture:** the enclosure must have an open window or IR-transparent
  cover in front of U2. See ST AN4907 for cover-window spacing rules.
