import pcbnew, sys
F="/usr/share/kicad/footprints"
for spec in sys.argv[1:]:
    lib,name=spec.split(":")
    fp=pcbnew.FootprintLoad(f"{F}/{lib}.pretty",name)
    bb=fp.GetBoundingBox(False)
    cy=fp.GetCourtyard(pcbnew.F_CrtYd).BBox() if fp.GetCourtyard(pcbnew.F_CrtYd).OutlineCount() else bb
    print(spec, "bbox mm", round(pcbnew.ToMM(cy.GetLeft()),2), round(pcbnew.ToMM(cy.GetTop()),2), round(pcbnew.ToMM(cy.GetRight()),2), round(pcbnew.ToMM(cy.GetBottom()),2))
    if "MINI" in name:
        ys=[pcbnew.ToMM(p.GetPosition().y) for p in fp.Pads()]
        print("  pad y range", min(ys), max(ys))
        for d in fp.GraphicalItems():
            if d.GetClass()=="PCB_TEXT": print("  text", d.GetText(), pcbnew.ToMM(d.GetPosition().y))
        for z in fp.Zones(): print("  zone", z.GetIsRuleArea(), pcbnew.ToMM(z.GetBoundingBox().GetTop()), pcbnew.ToMM(z.GetBoundingBox().GetBottom()))
