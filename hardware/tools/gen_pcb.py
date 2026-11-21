"""Generate slidepod.kicad_pcb from circuit.py: outline, 4-layer stackup, placed footprints,
nets, net classes and ground pours. Routing is left to KiCad (or Freerouting).

Board frame (front view, y grows downward):
  top edge    = antenna end (the module's keep-out band spans the full width there)
  bottom edge = toward the lead-pipe tube (the mount saddles it 12.5 mm above this edge)
  The VL53L1X faces out of the front (F.Cu) side, toward the outer slide crossbar.

rev 0.2 (32 x 26 mm, double-sided): the front holds only what must be seen or reached
(module, ToF, LEDs, accelerometer, USB-C, switch); everything else is
packed on the back, between the board and the LiPo. The LiPo sits behind y > ~6 so it is
never behind the antenna.

Placement: ANCHORS are fixed. Every other part is packed on the back by a spiral search
from a target point (explicit, or the centroid of the already-placed pads it shares a
signal net with) to the nearest spot where its courtyard collides with nothing.
"""
import math
import sys
import uuid

import pcbnew

sys.path.insert(0, "/work/tools")
import circuit  # noqa: E402
from stackup import IN2_PLANE  # noqa: E402

NS = uuid.UUID("6b1d6a52-6f0c-4f4e-9d1a-5e1c0d7a51de")
FPLIB = "/usr/share/kicad/footprints"
W, H = 32.0, 26.0          # board size, mm
OX, OY = 100.0, 100.0      # board origin on the sheet
EDGE = 0.4                 # courtyard-to-edge margin for packed parts
GAP = 0.15                 # extra courtyard spacing between packed parts
BACK_EDGE = 1.2            # back parts stay this far in, leaving a ledge for the mount

# Fixed parts on the front: ref -> (x, y, rotation_deg), board coordinates.
SENSOR_X = 19.8            # the ToF must sit over the brace; the mount centres on this x
ANCHORS = {
    "U1": (8.2, 10.95, 0),       # module top at the top edge, antenna up, left side
    "U2": (SENSOR_X, 7.6, 0),    # ToF just below the antenna keep-out band
    "SW3": (30.2, 10.35, 90),    # power slide switch, lever out the right edge
    "J1": (27.8, 20.37, 90),     # USB-C, mouth out the right edge
    "LED1": (18.4, 12.0, 0),     # status LEDs stacked between module and USB-C: R, G, B
    "LED2": (18.4, 13.8, 0),
    "LED3": (18.4, 15.6, 0),
    "D3": (18.4, 17.4, 0),       # charge LED
    "U7": (19.6, 20.7, 0),       # accelerometer, in the gap below the LEDs, left of USB-C
    "C17": (18.6, 22.9, 180),    # its decoupling caps, +3V3 pad next to VDDIO (pin 5) and VDD (pin 8)
    "C18": (21.0, 22.9, 0),
}
# Fixed parts on the back: ref -> (x, y, mouth direction). The LiPo (25 x 20) covers the
# back from x ~7 to the right edge, 1.7 mm off the board, leads out of its left end. The
# JST-SH sits in the strip left of it with its mouth up (-y): the leads leave the cell, turn
# up and plug in from above instead of wrapping round the left edge. (Facing the cell does
# not fit: the strip is 7 mm and the ~3 mm tall plug would run under the cell.) The rotation
# is picked from the pad layout.
BACK_ANCHORS = {
    "J2": (3.73, 13.85, "-y"),
}
JST_PLUG = (0.4, 6.0, 7.0, 10.5)     # back keep-clear above J2's mouth: plug + lead bend

# Explicit targets for back-side parts whose nets don't pull them to the right place.
# Value: (x, y) or ("pad", ref, padnum).
TARGETS = {
    "U3": (24.0, 12.0), "U4": (12.0, 12.0),
    # USB ESD: on the USB lines between USB-C and the module's USB pins (23/24), below the
    # module where the front is empty. Under the IMU its VBUS pin could never get a via out.
    "U6": (14.5, 23.0),
    "Q1": (26.0, 9.0), "D2": (21.6, 9.0),
    "C6": ("pad", "U1", "3"), "C7": ("pad", "U1", "3"), "C8": ("pad", "U1", "3"),
    "C10": ("pad", "U2", "1"), "C11": ("pad", "U2", "1"), "C12": ("pad", "U2", "11"),
    "C4": ("pad", "U4", "5"), "C3": ("pad", "U4", "1"),
    "C1": ("pad", "U3", "4"), "C2": ("pad", "U3", "3"),
    # Pull-ups. The ToF's sit on the back under the module, beside its ToF pins (32-35): the
    # back around the ToF itself is full of power parts. The IMU's go by the IMU's top row.
    "R15": (13.6, 17.0), "R16": (13.6, 16.0), "R17": (13.6, 18.6), "R18": (13.6, 17.8),
    "R19": (19.0, 18.9), "R20": (19.8, 18.9),
    "R5": ("pad", "Q1", "1"),
    "R6": ("pad", "R7", "1"),   # keep the battery-sense divider together at the ADC pin
    "TP1": (2.0, 8.0), "TP2": (4.0, 8.0), "TP3": (6.0, 8.0), "TP4": (2.0, 10.0),
    # UART pads beside the module's U0TXD/U0RXD pins (39/40): far left, their traces ran
    # down the module's right edge and blocked the sensor/LED pins.
    "TP6": (14.3, 12.9), "TP7": (14.3, 11.4), "TP8": (2.0, 12.0),
    "TP9": (4.0, 12.0),
}

# Back parts whose orientation matters: ref -> (pad, direction of that pad from the part centre).
# D2 stands with VSYS_IN up, beside Q1's VSYS_IN pin, and VBUS down toward Q1's gate and the
# charger, so VBUS stays right of the ToF/LED corridor. (VBUS up put it between D2 and Q1; lying
# along x put the VBUS pad, and the VBUS trunk, in the corridor the ToF bus needs.)
PAD_DIR = {"D2": ("1", "-y")}

# Packing order: ICs first so passives can be pulled toward their pins.
ORDER_FIRST = ["U3", "U6", "U4", "Q1", "D2", "R7",   # R7 before R6 (R6 targets it)
               "TP6", "TP7"]                         # before the passives fill the module edge

GLOBAL_NETS = {"GND", "+3V3"}   # too widespread to use as attraction
POWER_NETS = ["VBUS", "VBAT", "VSYS", "VSYS_IN", "+3V3"]

ANT_BAND = 6.0             # antenna keep-out band depth from the top edge (module zone + margin)
TOOLING = [(30.5, 1.5), (17.5, 1.5), (1.5, 24.5)]   # 1.0 mm NPTH, clear of every part
# Keep-clear rectangles (x0, y0, x1, y1). Front: antenna band, ToF field of view.
RESERVED = [(0, 0, W, ANT_BAND), (SENSOR_X - 3.0, ANT_BAND, SENSOR_X + 3.0, 9.6)]
# Back: antenna band; anchors with holes through the board are added at run time.
RESERVED_BACK = [(0, 0, W, ANT_BAND)] + [(x - 1.0, y - 1.0, x + 1.0, y + 1.0) for x, y in TOOLING]
RESERVED_BACK.append(JST_PLUG)
THROUGH = ["J1", "SW3"]    # front parts whose holes block the back


def mm(v):
    return pcbnew.FromMM(v)


def pt(x, y):
    return pcbnew.VECTOR2I(mm(OX + x), mm(OY + y))


def to_board(v):
    return pcbnew.ToMM(v.x) - OX, pcbnew.ToMM(v.y) - OY


def courtyard(fp):
    cy = fp.GetCourtyard(pcbnew.B_CrtYd if fp.IsFlipped() else pcbnew.F_CrtYd)
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
    power.SetTrackWidth(mm(0.25))  # ~0.7 A on 1 oz outer, ~0.4 A on 0.5 oz In2; peaks here ~350 mA
    power.SetClearance(mm(0.15))
    power.SetViaDiameter(mm(0.45))  # standard via: 0.6 mm ones crowded the 3-layer routing
    power.SetViaDrill(mm(0.2))
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

    # Tooling holes for JLCPCB pick-and-place (3 × 1.0 mm NPTH, three corners)
    for th_i, (tx, ty) in enumerate(TOOLING, 1):
        th = pcbnew.FOOTPRINT(board)
        th.SetReference(f"TH{th_i}")
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
        board.Add(th)

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
        for fname, ftext in (("LCSC", p.lcsc), ("Note", p.note)):   # mirror the symbol's fields
            if ftext:
                f = pcbnew.PCB_FIELD(fp, pcbnew.FIELD_T_USER, fname)
                f.SetText(ftext)
                f.SetVisible(False)
                f.SetLayer(pcbnew.F_Fab)
                fp.Add(f)
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

    placed = []        # front: (ref, bbox, poly)
    placed_back = []   # back

    def collides(ref, poly, bb, edge=True, back=False):
        e = BACK_EDGE if back else EDGE
        if edge and (bb[0] < e or bb[1] < e or bb[2] > W - e or bb[3] > H - e):
            return True
        for r in (RESERVED_BACK if back else RESERVED):
            if rect_overlap(bb, r):
                return True
        for oref, obb, opoly in (placed_back if back else placed):
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
        (placed_back if fp.IsFlipped() else placed).append((ref, bbox_mm(poly), poly))

    for ref, (x, y, r) in ANCHORS.items():
        fps[ref].SetPosition(pt(x, y))
        fps[ref].SetOrientationDegrees(r)
        commit(ref)
        if ref in THROUGH:
            RESERVED_BACK.append(bbox_mm(courtyard(fps[ref])))

    def mouth_dir(fp):
        """Unit-ish direction from the signal pins toward the mounting tabs (the mouth)."""
        sig = [p.GetPosition() for p in fp.Pads() if p.GetNumber() not in ("MP", "")]
        mp = [p.GetPosition() for p in fp.Pads() if p.GetNumber() == "MP"]
        sx = sum(p.x for p in sig) / len(sig); sy = sum(p.y for p in sig) / len(sig)
        mx = sum(p.x for p in mp) / len(mp); my = sum(p.y for p in mp) / len(mp)
        return mx - sx, my - sy

    want = {"-x": (-1, 0), "+x": (1, 0), "-y": (0, -1), "+y": (0, 1)}
    for ref, (x, y, d) in BACK_ANCHORS.items():
        fp = fps[ref]
        fp.SetLayerAndFlip(pcbnew.B_Cu)
        fp.SetPosition(pt(x, y))
        best = None
        for rot in (0, 90, 180, 270):
            fp.SetOrientationDegrees(rot)
            dx, dy = mouth_dir(fp)
            score = dx * want[d][0] + dy * want[d][1]
            if best is None or score > best[0]:
                best = (score, rot)
        fp.SetOrientationDegrees(best[1])
        commit(ref)

    def target_of(ref):
        t = TARGETS.get(ref)
        if isinstance(t, tuple) and t and t[0] == "pad":
            return to_board(fps[t[1]].FindPadByNumber(t[2]).GetPosition())
        if t:
            return t
        mynets = {n for n in parts[ref].pins.values() if n not in GLOBAL_NETS}
        pts = []
        placed_refs = {p[0] for p in placed + placed_back}
        for oref in placed_refs:
            for pad in fps[oref].Pads():
                if pad.GetNetname() in mynets:
                    pts.append(to_board(pad.GetPosition()))
        if not pts:
            return W / 2, H / 2
        return sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)

    def rots_for(ref):
        if ref not in PAD_DIR:
            return (0, 90)
        num, d = PAD_DIR[ref]
        fp, ok = fps[ref], []
        for rot in (0, 90, 180, 270):
            fp.SetOrientationDegrees(rot)
            v = fp.FindPadByNumber(num).GetPosition() - fp.GetPosition()
            if v.x * want[d][0] + v.y * want[d][1] > 0:
                ok.append(rot)
        return ok

    rest = [p.ref for p in circuit.PARTS if p.ref not in ANCHORS and p.ref not in BACK_ANCHORS]
    rest = [r for r in ORDER_FIRST if r in rest] + [r for r in rest if r not in ORDER_FIRST]
    failed = []
    for ref in rest:
        fp = fps[ref]
        fp.SetLayerAndFlip(pcbnew.B_Cu)     # everything not anchored goes on the back
        tx, ty = target_of(ref)
        done = False
        step = 0.25
        for ring in range(0, 120):
            rad = ring * step
            n = max(1, int(2 * math.pi * rad / step))
            for k in range(n):
                a = 2 * math.pi * k / n
                x, y = tx + rad * math.cos(a), ty + rad * math.sin(a)
                for rot in rots_for(ref):
                    fp.SetPosition(pt(x, y))
                    fp.SetOrientationDegrees(rot)
                    poly = courtyard(fp)
                    if not collides(ref, poly, bbox_mm(poly), back=True):
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

    # Stackup: F.Cu signals + GND pour | In1 GND plane | In2 +3V3 | B.Cu signals + GND pour.
    # stackup.IN2_PLANE picks whether In2 is a solid +3V3 plane (pads reach it by fan-out vias)
    # or a third routing layer whose +3V3 pour only fills what the routing leaves. The module's
    # rule area keeps every pour off the antenna.
    board.SetLayerType(pcbnew.In1_Cu, pcbnew.LT_POWER)
    board.SetLayerType(pcbnew.In2_Cu, pcbnew.LT_POWER if IN2_PLANE else pcbnew.LT_MIXED)
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

    # Full-width antenna keep-out: the module's own rule area stops short of the right edge.
    ka = pcbnew.ZONE(board)
    ka.SetIsRuleArea(True)
    ka.SetLayerSet(pcbnew.LSET.AllCuMask())
    ka.SetDoNotAllowTracks(True)
    ka.SetDoNotAllowVias(True)
    ka.SetDoNotAllowZoneFills(True)
    ka.SetDoNotAllowPads(False)
    ka.SetDoNotAllowFootprints(False)
    ka.SetZoneName("antenna keep-out")
    ol = ka.Outline()
    ol.NewOutline()
    for x, y in ((0, 0), (W, 0), (W, 5.75), (0, 5.75)):
        ol.Append(mm(OX + x), mm(OY + y))
    board.Add(ka)

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
