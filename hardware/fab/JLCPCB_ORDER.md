# JLCPCB Order Instructions — SlidePod rev 0.1

Place the order at https://jlcpcb.com. All files needed are in this directory (`hardware/fab/`).

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
| Surface Finish | HASL(with lead) or LeadFree HASL |
| Quantity | 5 |
| Different Design | 1 |

Leave impedance control, blind/buried vias, castellated holes all off/no.

## Step 3 — Enable PCB Assembly

Toggle **PCB Assembly** on (right side of the page).

| Option | Value |
|---|---|
| Assembly Side | Top |
| Tooling Holes | Added by JLCPCB (or confirm the 3 × 1.0 mm NPTH holes in the preview) |
| Confirm Parts Placement | Yes |

Click **Confirm** to proceed to the assembly step.

## Step 4 — Upload BOM and CPL

When prompted:
- BOM file: `slidepod-bom.csv`
- CPL file: `slidepod-cpl.csv`

Click **Process BOM & CPL**.

## Step 5 — Verify parts

JLCPCB will show a parts table. Check each row:

**These parts are confirmed Basic or Extended and should match automatically:**

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
| C318884 | TS-1187A-B-A-B (×2) | Confirm available |
| C431540 | MSK12C02 | Confirm available |
| C15127 | AO3401A | Basic |
| C8598 | B5819W | Basic |
| C2286 | KT-0603R red LED (×2) | Basic |
| C12624 | KT-0603G green LED | Extended |
| C2288 | KT-0603B blue LED | Extended |

**If any part shows "Shortfall" or "No stock":** note it and either select an alternative LCSC part or accept that it will be hand-soldered (do not cancel the whole order for one part).

Passives (resistors C25105/C25744/etc., capacitors C19666/C19702/etc.) are all Basic and will auto-match.

## Step 6 — Placement preview and rotation check

After confirming parts, JLCPCB shows each component placed on the board. **Rotations must be verified** — KiCad's zero orientation differs from JLCPCB's for most IC packages.

Go through every component and visually confirm pin 1 / cathode / gate orientation matches the silkscreen. Parts most likely to need rotation correction:

| Ref | Package | Check |
|---|---|---|
| U1 | ESP32-S3-MINI-1 | Pin 1 at top-left; antenna faces board top edge |
| U2 | VL53L1CX (12-pad LGA) | Pin 1 marker at correct corner |
| U3 | MCP73831 (SOT-23-5) | Pin 1 (STAT) orientation |
| U4 | ME6211 (SOT-23-5) | Pin 1 (IN) orientation |
| U5 | MCP6001 (SOT-23-5) | Pin 1 (OUT) orientation |
| U6 | USBLC6-2SC6 (SOT-23-6) | Pin 1 (DM) orientation |
| Q1 | AO3401A (SOT-23) | Gate at pin 1 |
| D1 | BAT54S (SOT-23) | Cathode orientation |
| D2 | B5819W (SOD-123) | Cathode stripe matches silkscreen |
| D3, LED1 | 0603 red LED | Cathode (K) pad |
| LED2 | 0603 green LED | Cathode (K) pad |
| LED3 | 0603 blue LED | Cathode (K) pad |
| J1 | USB-C 16-pin | Mouth faces left board edge |
| J2 | JST-PH 2-pin | Opening faces right board edge |
| SW3 | MSK12C02 (slide switch) | Lever faces right board edge |

JLCPCB lets you rotate parts in the preview UI by clicking them. Correct any that look wrong before proceeding.

## Step 7 — Quote and order

Review the price breakdown (expect ~$24 in Extended part setup fees on top of the per-unit assembly cost). Proceed through shipping and payment.

---

## Notes

- **R24 is DNP** (do not place) — it is not in the BOM or CPL, so JLCPCB will not assemble it. This is correct.
- **J3 (piezo pads) and test points** are not in the BOM — they are hand-soldered or probe points. Correct.
- **JST-PH battery polarity** is not standardised across vendors. When the battery arrives, verify the `+` lead against the `+` marking on the board before connecting.
- **VL53L1X aperture**: the enclosure must have an open window or IR-transparent cover in front of U2. See ST AN4907 for cover-window spacing rules.
