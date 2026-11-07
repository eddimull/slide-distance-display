"""Add three 1.0 mm NPTH tooling holes to the existing routed board.

Patches slidepod.kicad_pcb in-place; routing is not touched.
Run once, then `make fab` to regenerate fab outputs.

  tools/kicad.sh python3 tools/add_tooling_holes.py
"""
import pcbnew

PCB = "/work/slidepod.kicad_pcb"
mm = pcbnew.FromMM
OX, OY = 100.0, 100.0


def pt(x, y):
    return pcbnew.VECTOR2I(mm(OX + x), mm(OY + y))


b = pcbnew.LoadBoard(PCB)

# Remove any tooling holes added by a previous run of this script.
for fp in list(b.GetFootprints()):
    if fp.GetReference().startswith("TH"):
        b.Delete(fp)

for i, (tx, ty) in enumerate([(1.5, 1.5), (28.5, 1.5), (1.5, 48.5)], 1):
    th = pcbnew.FOOTPRINT(b)
    th.SetReference(f"TH{i}")
    th.SetPosition(pt(tx, ty))
    th.SetExcludedFromBOM(True)
    th.SetExcludedFromPosFiles(True)
    pad = pcbnew.PAD(th)
    pad.SetShape(pcbnew.PAD_SHAPE_CIRCLE)
    pad.SetAttribute(pcbnew.PAD_ATTRIB_NPTH)
    pad.SetDrillShape(pcbnew.PAD_DRILL_SHAPE_CIRCLE)
    pad.SetDrillSize(pcbnew.VECTOR2I(mm(1.0), mm(1.0)))
    pad.SetSize(pcbnew.VECTOR2I(mm(1.0), mm(1.0)))
    pad.SetPosition(pt(tx, ty))
    pad.SetNumber("")
    th.Add(pad)
    b.Add(th)
    print(f"Added TH{i} at ({tx}, {ty}) mm")

b.Save(PCB)
print("Saved. Run `make fab` to regenerate fab outputs.")
