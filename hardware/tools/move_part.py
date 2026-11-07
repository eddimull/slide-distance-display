"""Move one footprint on the routed board to the nearest legal spot near a target,
then strip the traces left dangling at its old position. Follow with finish_route.py.

  python3 tools/move_part.py R6 R7 1    (move R6 next to pad 1 of R7)
"""
import math
import sys

import pcbnew

PCB = "/work/slidepod.kicad_pcb"
CLR = 0.2
mm = pcbnew.FromMM
ref, tref, tpad = sys.argv[1:4]
b = pcbnew.LoadBoard(PCB)
fp = b.FindFootprintByReference(ref)
target = b.FindFootprintByReference(tref).FindPadByNumber(tpad).GetPosition()

# detach copper connected only through this part's pads
old_pads = [(p.GetPosition(), p.GetNetCode()) for p in fp.Pads()]


def legal():
    fp.BuildCourtyardCaches()   # courtyards are cached; refresh after every move
    cy = fp.GetCourtyard(pcbnew.F_CrtYd)
    e = b.GetBoardEdgesBoundingBox()
    if not e.Contains(cy.BBox()):
        return False
    for other in b.GetFootprints():
        if other.GetReference() == ref:
            continue
        oc = other.GetCourtyard(pcbnew.F_CrtYd)
        if oc.OutlineCount() and cy.BBox().Intersects(oc.BBox()):
            inter = cy.CloneDropTriangulation()
            inter.BooleanIntersection(oc)
            if inter.OutlineCount():
                return False
    for pad in fp.Pads():
        sh = pad.GetEffectiveShape(pcbnew.F_Cu)
        for t in b.GetTracks():
            if not t.IsOnLayer(pcbnew.F_Cu):
                continue
            if t.Type() == pcbnew.PCB_VIA_T:
                r = t.GetWidth(pcbnew.F_Cu) // 2
                if sh.Collide(pcbnew.SEG(t.GetPosition(), t.GetPosition()), r + mm(CLR)):
                    return False
            elif sh.Collide(pcbnew.SEG(t.GetStart(), t.GetEnd()), t.GetWidth() // 2 + mm(CLR)):
                return False
    return True


placed = False
for ring in range(1, 60):
    rad = mm(0.25 * ring)
    for k in range(max(8, ring * 4)):
        a = 2 * math.pi * k / max(8, ring * 4)
        for rot in (0, 90):
            fp.SetPosition(pcbnew.VECTOR2I(int(target.x + rad * math.cos(a)), int(target.y + rad * math.sin(a))))
            fp.SetOrientationDegrees(rot)
            if legal():
                placed = True
                break
        if placed:
            break
    if placed:
        break
if not placed:
    raise SystemExit(f"no legal spot for {ref}")
fp.Reference().SetPosition(fp.GetPosition())

# remove traces/vias that are now dangling (iteratively), except plane vias
removed = 0
for _ in range(20):
    b.BuildConnectivity()
    conn = b.GetConnectivity()
    stubs = [t for t in list(b.Tracks()) if conn.TestTrackEndpointDangling(t, False)
             and not (t.Type() == pcbnew.PCB_VIA_T and t.GetNetname() in ("GND", "+3V3"))]
    if not stubs:
        break
    for t in stubs:
        b.Delete(t)
    removed += len(stubs)
pcbnew.ZONE_FILLER(b).Fill(b.Zones())
b.Save(PCB)
p = fp.GetPosition()
print(f"moved {ref} to ({pcbnew.ToMM(p.x):.2f}, {pcbnew.ToMM(p.y):.2f}) rot {fp.GetOrientationDegrees():.0f}; "
      f"removed {removed} dangling items")
