"""Freerouting round trip.

  python3 tools/route.py export   -> slidepod.dsn (In1.Cu GND plane kept, and In2.Cu +3V3 plane if
                                     stackup.IN2_PLANE; the routing layers' pours removed; vias kept EDGE_VIA mm off the board edge)
  java -jar freerouting.jar -de slidepod.dsn -do slidepod.ses ...
  python3 tools/route.py import   -> imports slidepod.ses into slidepod.kicad_pcb, refills all pours
"""
import re
import sys

import pcbnew

from stackup import IN2_PLANE

PCB = "/work/slidepod.kicad_pcb"
SES = "/work/slidepod.ses"
EDGE_VIA = 0.55   # board-edge clearance 0.3 + via radius 0.225


def export():
    b = pcbnew.LoadBoard(PCB)
    edges = [d.GetBoundingBox() for d in b.GetDrawings() if d.GetLayer() == pcbnew.Edge_Cuts]
    b.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
    b.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER if IN2_PLANE else pcbnew.LT_SIGNAL)
    planes = (pcbnew.In1_Cu, pcbnew.In2_Cu) if IN2_PLANE else (pcbnew.In1_Cu,)
    for z in list(b.Zones()):
        if not z.GetIsRuleArea() and z.GetLayer() not in planes:
            b.Remove(z)
    # Freerouting ignores the board-edge clearance for vias: add a via-only keep-out frame.
    x0, y0 = min(r.GetLeft() for r in edges), min(r.GetTop() for r in edges)
    x1, y1 = max(r.GetRight() for r in edges), max(r.GetBottom() for r in edges)
    d = pcbnew.FromMM(EDGE_VIA)
    for rx0, ry0, rx1, ry1 in ((x0, y0, x1, y0 + d), (x0, y1 - d, x1, y1),
                               (x0, y0, x0 + d, y1), (x1 - d, y0, x1, y1)):
        k = pcbnew.ZONE(b)
        k.SetIsRuleArea(True)
        k.SetLayerSet(pcbnew.LSET.AllCuMask())
        k.SetDoNotAllowVias(True)
        k.SetDoNotAllowTracks(False)
        k.SetDoNotAllowZoneFills(False)
        k.SetDoNotAllowPads(False)
        k.SetDoNotAllowFootprints(False)
        for x, y in ((rx0, ry0), (rx1, ry0), (rx1, ry1), (rx0, ry1)):
            k.AppendCorner(pcbnew.VECTOR2I(x, y), -1)
        b.Add(k)
    pcbnew.ZONE_FILLER(b).Fill(b.Zones())
    ok = pcbnew.ExportSpecctraDSN(b, "/work/slidepod.dsn")
    print("exported slidepod.dsn" if ok else "DSN export FAILED")


def import_(lock=False):
    b = pcbnew.LoadBoard(PCB)
    b.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
    b.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER if IN2_PLANE else pcbnew.LT_MIXED)
    # Freerouting lists footprints without a library id (the NPTH tooling holes) under
    # "(component " with an empty name, which KiCad's SES parser rejects: drop that block.
    ses = open(SES).read()
    ses = re.sub(r"\(component \n(\s*\(place [^\n]*\n)+\s*\)\n\s*", "", ses)
    # cleaned copy in /tmp: the Freerouting container may have written SES as root
    open("/tmp/slidepod.ses", "w").write(ses)
    ok = pcbnew.ImportSpecctraSES(b, "/tmp/slidepod.ses")
    if not ok:
        raise SystemExit("SES import FAILED")
    if lock:
        for t in b.GetTracks():
            t.SetLocked(True)
    pcbnew.ZONE_FILLER(b).Fill(b.Zones())
    b.Save(PCB)
    print(f"imported: {len(b.GetTracks())} tracks/vias" + (" (all locked)" if lock else ""))


if __name__ == "__main__":
    {"export": export, "import": import_, "import-lock": lambda: import_(lock=True)}[sys.argv[1]]()
