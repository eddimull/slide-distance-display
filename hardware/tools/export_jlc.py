"""Write JLCPCB assembly files from slidepod.kicad_pcb and the kicad-cli position file.

  fab/slidepod-bom.csv   Comment, Designator, Footprint, LCSC Part #
  fab/slidepod-cpl.csv   Designator, Mid X, Mid Y, Layer, Rotation

Parts that are DNP or excluded from the BOM (test points, piezo pads) are left out.
Check rotations in JLC's placement preview; library zero-orientations differ from JLC's.
"""
import csv
import sys
from collections import OrderedDict

import pcbnew

sys.path.insert(0, "/work/tools")
import circuit  # noqa: E402

parts = {p.ref: p for p in circuit.PARTS}
b = pcbnew.LoadBoard("/work/slidepod.kicad_pcb")

groups = OrderedDict()
placed = set()
for fp in sorted(b.GetFootprints(), key=lambda f: f.GetReference()):
    ref = fp.GetReference()
    if fp.IsDNP() or fp.IsExcludedFromBOM():
        continue
    p = parts[ref]
    key = (p.value, fp.GetFPID().GetLibItemName().wx_str(), p.lcsc)
    groups.setdefault(key, []).append(ref)
    placed.add(ref)

with open("/work/fab/slidepod-bom.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
    for (value, fpname, lcsc), refs in groups.items():
        w.writerow([value, ",".join(refs), fpname, lcsc])

with open("/work/fab/slidepod-pos.csv") as f, open("/work/fab/slidepod-cpl.csv", "w", newline="") as g:
    w = csv.writer(g)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    for row in csv.DictReader(f):
        if row["Ref"] in placed:
            w.writerow([row["Ref"], row["PosX"] + "mm", row["PosY"] + "mm",
                        "Top" if row["Side"] == "top" else "Bottom", row["Rot"]])

missing = sorted({r for refs in groups.values() for r in refs if not parts[r].lcsc})
print(f"BOM: {len(groups)} lines, {len(placed)} placements; no LCSC # yet: {', '.join(missing)}")
