"""Freerouting round trip.

  python3 tools/route.py export   -> slidepod.dsn (In1.Cu GND and In2.Cu +3V3 planes kept; F/B pours removed for routing)
  java -jar freerouting.jar -de slidepod.dsn -do slidepod.ses ...
  python3 tools/route.py import   -> imports slidepod.ses into slidepod.kicad_pcb, refills all pours
"""
import sys

import pcbnew

PCB = "/work/slidepod.kicad_pcb"


def export():
    b = pcbnew.LoadBoard(PCB)
    b.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
    b.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER)
    for z in list(b.Zones()):
        if not z.GetIsRuleArea() and z.GetLayer() not in (pcbnew.In1_Cu, pcbnew.In2_Cu):
            b.Remove(z)
    pcbnew.ZONE_FILLER(b).Fill(b.Zones())
    ok = pcbnew.ExportSpecctraDSN(b, "/work/slidepod.dsn")
    print("exported slidepod.dsn" if ok else "DSN export FAILED")


def import_(lock=False):
    b = pcbnew.LoadBoard(PCB)
    b.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
    b.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER)
    ok = pcbnew.ImportSpecctraSES(b, "/work/slidepod.ses")
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
