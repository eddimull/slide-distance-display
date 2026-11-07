"""Generate slidepod.kicad_pcb from circuit.py: outline, 4-layer stackup, placed footprints,
nets, net classes and ground pours. Routing is left to KiCad (or Freerouting).

Board frame (front view, y grows downward):
  top edge    = antenna end (keep-out rule area from the module footprint covers it)
  bottom edge = sits on the inner slide tube (clamp + piezo solder pads)
  The VL53L1X faces out of the front (F.Cu) side, toward the slide crook.

Placement: ANCHORS are fixed. Every other part is packed by a spiral search from a
target point (explicit, or the centroid of the already-placed pads it shares a
signal net with) to the nearest spot where its courtyard collides with nothing.
"""
import math
import sys
import uuid

import pcbnew

sys.path.insert(0, "/work/tools")
import circuit  # noqa: E402

NS = uuid.UUID("6b1d6a52-6f0c-4f4e-9d1a-5e1c0d7a51de")
FPLIB = "/usr/share/kicad/footprints"
W, H = 30.0, 50.0          # board size, mm
OX, OY = 100.0, 100.0      # board origin on the sheet
EDGE = 0.4                 # courtyard-to-edge margin for packed parts
GAP = 0.15                 # extra courtyard spacing between packed parts

# Fixed parts: ref -> (x, y, rotation_deg), board coordinates.
ANCHORS = {
    "U1": (15.0, 10.95, 0),      # module top at the top edge, antenna up
    "U2": (15.0, 30.5, 0),       # ToF, centre of the front face
    "LED1": (13.0, 25.6, 90),     # status LEDs side by side under the module: R, G, B
    "LED2": (15.0, 25.6, 90),
    "LED3": (17.0, 25.6, 90),
    "SW1": (4.4, 25.6, 0),       # RESET
    "SW2": (25.6, 25.6, 0),      # BOOT
    "J1": (4.2, 34.6, 270),      # USB-C, mouth out the left edge, high so D+/D- run short to the ESP32
    "J2": (25.0, 36.0, 90),      # battery JST, opening to the right edge
    "SW3": (28.2, 45.3, 90),     # power slide switch, lever out the right edge
    "J3": (13.2, 48.4, 0),       # piezo solder pads, bottom edge
}

# Explicit targets for parts whose nets don't pull them to the right place.
# Value: (x, y) or ("pad", ref, padnum).
TARGETS = {
    "U3": (15.5, 39.0), "U4": (19.5, 44.0), "U6": (9.6, 33.0), "U5": (6.0, 45.5),
    "Q1": (19.0, 40.5), "D2": (15.5, 42.5), "D1": (9.5, 47.5),
    "C6": ("pad", "U1", "3"), "C7": ("pad", "U1", "3"), "C8": ("pad", "U1", "3"),
    "C10": ("pad", "U2", "1"), "C11": ("pad", "U2", "1"), "C12": ("pad", "U2", "11"),
    "C14": ("pad", "U5", "5"), "C4": ("pad", "U4", "5"), "C3": ("pad", "U4", "1"),
    "C1": ("pad", "U3", "4"), "C2": ("pad", "U3", "3"),
    "R15": (24.5, 14.0), "R16": (26.0, 14.0), "R17": (24.5, 17.0), "R18": (26.0, 17.0),
    "R5": ("pad", "Q1", "1"),
    "R6": ("pad", "R7", "1"),   # keep the battery-sense divider together at the ADC pin
    "TP1": (3.0, 9.0), "TP2": (27.5, 9.0), "TP3": (3.0, 12.0), "TP4": (27.5, 12.0),
    "TP5": (3.0, 15.0), "TP6": (27.5, 15.0), "TP7": (27.5, 18.0),
}

# Packing order: ICs first so passives can be pulled toward their pins.
ORDER_FIRST = ["U3", "U6", "U4", "Q1", "D2", "U5", "D1", "R7"]  # R7 before R6 (R6 targets it)

GLOBAL_NETS = {"GND", "+3V3"}   # too widespread to use as attraction
POWER_NETS = ["VBUS", "VBAT", "VSYS", "VSYS_IN", "+3V3"]

# Keep-clear rectangles (x0, y0, x1, y1): antenna band, ToF field of view
RESERVED = [(0, 0, W, 6.6), (12.0, 28.6, 18.0, 32.4)]


def mm(v):
    return pcbnew.FromMM(v)


def pt(x, y):
    return pcbnew.VECTOR2I(mm(OX + x), mm(OY + y))


def to_board(v):
    return pcbnew.ToMM(v.x) - OX, pcbnew.ToMM(v.y) - OY


def courtyard(fp):
    cy = fp.GetCourtyard(pcbnew.F_CrtYd)
    if cy.OutlineCount() == 0:
        bb = fp.GetBoundingBox(False)
        cy = pcbnew.SHAPE_POLY_SET()
        cy.NewOutline()
        for x, y in ((bb.GetLeft(), bb.GetTop()), (bb.GetRight(), bb.GetTop()),
                     (bb.GetRight(), bb.GetBottom()), (bb.GetLeft(), bb.GetBottom())):
            cy.Append(x, y)
    return cy


def bbox_mm(poly):
    b = poly.BBox()
    return (pcbnew.ToMM(b.GetLeft()) - OX, pcbnew.ToMM(b.GetTop()) - OY,
            pcbnew.ToMM(b.GetRight()) - OX, pcbnew.ToMM(b.GetBottom()) - OY)


def rect_overlap(a, b, gap=0.0):
    return not (a[2] + gap <= b[0] or b[2] + gap <= a[0] or a[3] + gap <= b[1] or b[3] + gap <= a[1])


def main():
    board = pcbnew.NewBoard("/work/slidepod.kicad_pcb")
    board.SetCopperLayerCount(4)
    ds = board.GetDesignSettings()
    # JLCPCB 4-layer capabilities with some margin
    ds.m_TrackMinWidth = mm(0.127)
    ds.m_MinClearance = mm(0.127)
    ds.m_ViasMinSize = mm(0.45)
    ds.m_MinThroughDrill = mm(0.2)
    ds.m_CopperEdgeClearance = mm(0.3)
    ds.SetBoardThickness(mm(1.0))

    nc = ds.m_NetSettings
    default = nc.GetDefaultNetclass()
    default.SetTrackWidth(mm(0.15))
    default.SetClearance(mm(0.15))
    default.SetViaDiameter(mm(0.45))
    default.SetViaDrill(mm(0.2))
    power = pcbnew.NETCLASS("Power")
    power.SetTrackWidth(mm(0.3))   # ~1 A on 1 oz outer copper; plenty for 500 mA
    power.SetClearance(mm(0.15))
    power.SetViaDiameter(mm(0.6))
    power.SetViaDrill(mm(0.3))
    nc.SetNetclass("Power", power)
    for n in POWER_NETS:
        nc.SetNetclassPatternAssignment(n, "Power")
    # GND is carried by pours + stitching vias (tools/stitch.py), not routed by Freerouting.
    gnd = pcbnew.NETCLASS("GND")
    gnd.SetTrackWidth(mm(0.4))
    gnd.SetClearance(mm(0.15))
    gnd.SetViaDiameter(mm(0.45))
    gnd.SetViaDrill(mm(0.2))
    nc.SetNetclass("GND", gnd)
    nc.SetNetclassPatternAssignment("GND", "GND")
    # USB full-speed pair: routed first, on its own, then locked (see Makefile `route`).
    usb = pcbnew.NETCLASS("USB")
    usb.SetTrackWidth(mm(0.2))
    usb.SetClearance(mm(0.15))
    usb.SetViaDiameter(mm(0.45))
    usb.SetViaDrill(mm(0.2))
    nc.SetNetclass("USB", usb)
    nc.SetNetclassPatternAssignment("USB_D*", "USB")

    rect = pcbnew.PCB_SHAPE(board, pcbnew.SHAPE_T_RECT)
    rect.SetStart(pt(0, 0))
    rect.SetEnd(pt(W, H))
    rect.SetLayer(pcbnew.Edge_Cuts)
    rect.SetWidth(mm(0.1))
    board.Add(rect)

    nets = {}

    def net(name):
        if name not in nets:
            ni = pcbnew.NETINFO_ITEM(board, name)
            board.Add(ni)
            nets[name] = ni
        return nets[name]

    # Pad nets come from the schematic's exported netlist (run gen_sch.py + export first),
    # so the PCB matches the schematic exactly, including unconnected-(...) nets.
    from sexp import parse, find, find_all
    netlist = parse(open("/work/slidepod.net").read())
    sch_net = {}
    for n in find_all(find(netlist, "nets"), "net"):
        for node in find_all(n, "node"):
            sch_net[(find(node, "ref")[1], find(node, "pin")[1])] = find(n, "name")[1]

    fps, parts = {}, {p.ref: p for p in circuit.PARTS}
    for p in circuit.PARTS:
        lib, name = p.footprint.split(":")
        fp = pcbnew.FootprintLoad(f"{FPLIB}/{lib}.pretty", name)
        fp.SetFPID(pcbnew.LIB_ID(lib, name))
        fp.SetReference(p.ref)
        fp.SetValue(p.value)
        fp.SetPath(pcbnew.KIID_PATH("/" + str(uuid.uuid5(NS, f"sym/{p.ref}"))))
        fp.SetSheetfile("slidepod.kicad_sch")
        fp.SetSheetname("")
        if p.lcsc:
            f = pcbnew.PCB_FIELD(fp, fp.GetNextFieldId(), "LCSC")
            f.SetText(p.lcsc)
            f.SetVisible(False)
            f.SetLayer(pcbnew.F_Fab)
            fp.AddField(f)
        if p.dnp:
            fp.SetDNP(True)
        # Too dense for silkscreen references: keep them on F.Fab (assembly drawing).
        ref = fp.Reference()
        ref.SetLayer(pcbnew.F_Fab)
        ref.SetTextSize(pcbnew.VECTOR2I(mm(0.5), mm(0.5)))
        ref.SetTextThickness(mm(0.08))
        fp.Value().SetLayer(pcbnew.F_Fab)
        fp.Value().SetVisible(False)
        for pad in fp.Pads():
            n = sch_net.get((p.ref, pad.GetNumber()))
            if n:
                pad.SetNet(net(n))
        board.Add(fp)
        fps[p.ref] = fp

    placed = []   # (ref, bbox, poly)

    def collides(ref, poly, bb, edge=True):
        if edge and (bb[0] < EDGE or bb[1] < EDGE or bb[2] > W - EDGE or bb[3] > H - EDGE):
            return True
        for r in RESERVED:
            if rect_overlap(bb, r):
                return True
        for oref, obb, opoly in placed:
            if not rect_overlap(bb, obb, GAP):
                continue
            # Exact test only for big irregular courtyards (the module's includes its keep-out).
            if max(obb[2] - obb[0], obb[3] - obb[1]) > 12:
                inter = poly.CloneDropTriangulation()
                inter.Inflate(mm(GAP / 2), pcbnew.CORNER_STRATEGY_ROUND_ALL_CORNERS, mm(0.05))
                inter.BooleanIntersection(opoly)
                if inter.OutlineCount() == 0:
                    continue
            return True
        return False

    def commit(ref):
        fp = fps[ref]
        poly = courtyard(fp)
        placed.append((ref, bbox_mm(poly), poly))

    for ref, (x, y, r) in ANCHORS.items():
        fps[ref].SetPosition(pt(x, y))
        fps[ref].SetOrientationDegrees(r)
        commit(ref)

    def target_of(ref):
        t = TARGETS.get(ref)
        if isinstance(t, tuple) and t and t[0] == "pad":
            return to_board(fps[t[1]].FindPadByNumber(t[2]).GetPosition())
        if t:
            return t
        mynets = {n for n in parts[ref].pins.values() if n not in GLOBAL_NETS}
        pts = []
        placed_refs = {p[0] for p in placed}
        for oref in placed_refs:
            for pad in fps[oref].Pads():
                if pad.GetNetname() in mynets:
                    pts.append(to_board(pad.GetPosition()))
        if not pts:
            return W / 2, H / 2
        return sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)

    rest = [p.ref for p in circuit.PARTS if p.ref not in ANCHORS]
    rest = [r for r in ORDER_FIRST if r in rest] + [r for r in rest if r not in ORDER_FIRST]
    failed = []
    for ref in rest:
        fp = fps[ref]
        tx, ty = target_of(ref)
        done = False
        step = 0.25
        for ring in range(0, 120):
            rad = ring * step
            n = max(1, int(2 * math.pi * rad / step))
            for k in range(n):
                a = 2 * math.pi * k / n
                x, y = tx + rad * math.cos(a), ty + rad * math.sin(a)
                for rot in (0, 90):
                    fp.SetPosition(pt(x, y))
                    fp.SetOrientationDegrees(rot)
                    poly = courtyard(fp)
                    if not collides(ref, poly, bbox_mm(poly)):
                        commit(ref)
                        done = True
                        break
                if done:
                    break
            if done:
                break
        if not done:
            failed.append(ref)
            fp.SetPosition(pt(W + 5, 5 + 3 * len(failed)))

    for fp in fps.values():
        fp.Reference().SetPosition(fp.GetPosition())
        fp.Reference().SetTextAngleDegrees(0)

    # Stackup: F.Cu signals + GND pour | In1 GND plane | In2 +3V3 plane | B.Cu signals + GND pour.
    # The module's rule area keeps every pour off the antenna.
    board.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
    board.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER)
    for layer, zone_net in ((pcbnew.In1_Cu, "GND"), (pcbnew.In2_Cu, "+3V3"),
                            (pcbnew.F_Cu, "GND"), (pcbnew.B_Cu, "GND")):
        z = pcbnew.ZONE(board)
        z.SetLayer(layer)
        z.SetNet(net(zone_net))
        z.SetLocalClearance(mm(0.25))
        z.SetMinThickness(mm(0.2))
        z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
        z.SetThermalReliefGap(mm(0.2))
        z.SetThermalReliefSpokeWidth(mm(0.25))
        ol = z.Outline()
        ol.NewOutline()
        for x, y in ((0, 0), (W, 0), (W, H), (0, H)):
            ol.Append(mm(OX + x), mm(OY + y))
        board.Add(z)

    board.BuildConnectivity()
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.BuildConnectivity()
    board.Save("/work/slidepod.kicad_pcb")
    # Fills computed on the in-memory board miss NPTH knock-outs; reload and refill.
    board = pcbnew.LoadBoard("/work/slidepod.kicad_pcb")
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.Save("/work/slidepod.kicad_pcb")
    print(f"wrote slidepod.kicad_pcb ({W}x{H} mm): {len(fps)} footprints, {len(nets)} nets; "
          f"could not place: {failed}")


if __name__ == "__main__":
    main()
