"""Write JLCPCB assembly files from slidepod.kicad_pcb and the kicad-cli position file.

  fab/slidepod-bom.csv   Comment, Designator, Footprint, LCSC Part #
  fab/slidepod-cpl.csv   Designator, Mid X, Mid Y, Layer, Rotation

Parts with the same LCSC part number are merged onto one BOM line (avoids
"multiple lines matched to the same part" warning in JLCPCB's BOM upload).
Parts that are DNP or excluded from the BOM (test points, piezo pads) are left out.

Rotation and position offsets calibrated from the first physical order (2026-11-07).
JLCPCB rotations are CCW-positive; offsets are added to the kicad-cli CPL value.
Position offsets are in mm in CPL coordinates (kicad-cli negates Y vs. KiCad board).
Re-verify both tables in the placement preview on each new order.
"""
import csv
import sys
from collections import OrderedDict

import pcbnew

sys.path.insert(0, "/work/tools")
import circuit  # noqa: E402

# Rotation offsets (degrees, CCW-positive) added to the kicad-cli CPL rotation.
# "90° clockwise in preview" = -90° CCW = +270° mod 360.
# Keyed on LCSC number. Verified against the first physical order's placement preview.
LCSC_ROT_OFFSET = {
    "C47546":  90,   # BAT54S SOT-23: CPL 90 → 180
    "C15127":  90,   # AO3401A SOT-23: CPL 90 → 180
    "C424093": 270,  # MCP73831 SOT-23-5: CPL 0 → 270 (90° CW)
    "C82942":  270,  # ME6211 SOT-23-5: CPL 0 → 270 (90° CW)
    "C7519":   270,  # USBLC6-2SC6 SOT-23-6: CPL 0 → 270 (90° CW)
    "C116490": 180,  # MCP6001 SOT-23-5: CPL 0 → 180
    "C190004": 180,  # VL53L1CX LGA-12: CPL 0 → 180
}

# X/Y position offsets (mm) in CPL coordinates (kicad-cli negates Y vs. KiCad board).
# Keyed on designator. Applied when the JLCPCB part model origin differs from the
# KiCad footprint origin. Re-verify in the placement preview on each order.
CPL_XY_OFFSET = {
    "U1": (0.0, -2.5),   # ESP32-S3-MINI-1: model origin shifted toward antenna end
    "J1": (1.1,  0.0),   # USB-C TYPE-C-31-M-12: signal pins sat 1.1 mm short of pads
}

parts = {p.ref: p for p in circuit.PARTS}
b = pcbnew.LoadBoard("/work/slidepod.kicad_pcb")

# Group by LCSC part number so each physical part gets exactly one BOM line.
lcsc_groups = OrderedDict()  # lcsc_key -> {value, footprint, refs}
placed = set()
no_lcsc = []
for fp in sorted(b.GetFootprints(), key=lambda f: f.GetReference()):
    ref = fp.GetReference()
    if fp.IsDNP() or fp.IsExcludedFromBOM():
        continue
    p = parts[ref]
    fpname = fp.GetFPID().GetLibItemName().wx_str()
    if not p.lcsc:
        no_lcsc.append(ref)
        key = f"_NO_LCSC_{ref}"
    else:
        key = p.lcsc
    if key not in lcsc_groups:
        lcsc_groups[key] = {"value": p.value, "footprint": fpname, "refs": []}
    lcsc_groups[key]["refs"].append(ref)
    placed.add(ref)

with open("/work/fab/slidepod-bom.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
    for key, g in lcsc_groups.items():
        lcsc = "" if key.startswith("_NO_LCSC_") else key
        w.writerow([g["value"], ",".join(g["refs"]), g["footprint"], lcsc])

with open("/work/fab/slidepod-pos.csv") as f, open("/work/fab/slidepod-cpl.csv", "w", newline="") as g:
    w = csv.writer(g)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    for row in csv.DictReader(f):
        ref = row["Ref"]
        if ref not in placed:
            continue
        lcsc = parts[ref].lcsc
        rot = (float(row["Rot"]) + LCSC_ROT_OFFSET.get(lcsc, 0)) % 360
        dx, dy = CPL_XY_OFFSET.get(ref, (0.0, 0.0))
        x = float(row["PosX"]) + dx
        y = float(row["PosY"]) + dy
        w.writerow([ref, f"{x:.6f}mm", f"{y:.6f}mm",
                    "Top" if row["Side"] == "top" else "Bottom", f"{rot:.6f}"])

n_lines = len(lcsc_groups)
print(f"BOM: {n_lines} lines, {len(placed)} placements; no LCSC # yet: {', '.join(no_lcsc) or 'none'}")
