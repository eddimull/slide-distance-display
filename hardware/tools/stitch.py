"""Plane fan-out and GND stitching, around the Freerouting run.

  python3 tools/stitch.py fanout   (before routing, on the placed board)
      Every SMD pad on +3V3 or GND gets a via to its inner plane (+3V3 -> In2.Cu,
      GND -> In1.Cu) and a short F.Cu trace pad -> via. The new items are locked, so
      Freerouting routes the signals around them.
  python3 tools/stitch.py finish   (after importing the routes)
      Removes dangling stubs, adds GND stitching vias on a 3 mm grid, refills pours.

Every candidate is checked against other nets' copper, holes, the board edge and the
antenna keep-out.
"""
import math
import sys

import pcbnew

PCB = "/work/slidepod.kicad_pcb"
VIA_D, VIA_DRILL, CLR, HOLE_CLR, TRACK_W = 0.45, 0.2, 0.15, 0.25, 0.3
mm = pcbnew.FromMM

b = pcbnew.LoadBoard(PCB)
edge = b.GetBoardEdgesBoundingBox()
rule_areas = [z for z in b.Zones() if z.GetIsRuleArea()] + \
             [z for fp in b.GetFootprints() for z in fp.Zones() if z.GetIsRuleArea()]

# obstacles: (kind, shape | (centre, radius), netcode, clearance, keep_clear_even_same_net)
obstacles = []


def add_circle(c, r, net):
    # Vias keep clearance from every via, same net or not (drill-to-drill spacing).
    obstacles.append(("c", (c, r), net, mm(CLR), True))


def build_obstacles():
    obstacles.clear()
    for fp in b.GetFootprints():
        for pad in fp.Pads():
            if pad.IsOnLayer(pcbnew.F_Cu):
                obstacles.append(("s", pad.GetEffectiveShape(pcbnew.F_Cu), pad.GetNetCode(), mm(CLR), True))
            if pad.HasHole():
                obstacles.append(("s", pad.GetEffectiveHoleShape(), -1, mm(HOLE_CLR), True))
    for t in b.GetTracks():
        if t.Type() == pcbnew.PCB_VIA_T:
            add_circle(t.GetPosition(), t.GetWidth(pcbnew.F_Cu) // 2, t.GetNetCode())
        else:
            for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
                if t.IsOnLayer(layer):
                    obstacles.append(("s", t.GetEffectiveShape(layer), t.GetNetCode(), mm(CLR), False))


def via_ok(p, netcode):
    r = mm(VIA_D / 2)
    if not (edge.GetLeft() + mm(0.6) < p.x < edge.GetRight() - mm(0.6)
            and edge.GetTop() + mm(0.6) < p.y < edge.GetBottom() - mm(0.6)):
        return False
    for z in rule_areas:
        if z.GetDoNotAllowVias() and z.Outline().Collide(p, r + mm(0.1)):
            return False
    circ = pcbnew.SHAPE_CIRCLE(p, r)
    for kind, shape, net, clr, strict in obstacles:
        if net == netcode and not strict:
            continue
        if kind == "c":
            c, cr = shape
            if (c - p).EuclideanNorm() < cr + r + clr:
                return False
        elif shape.Collide(circ, clr):
            return False
    return True


def seg_ok(a, p, netcode):
    seg = pcbnew.SEG(a, p)
    hw = mm(TRACK_W / 2)
    sshape = pcbnew.SHAPE_SEGMENT(a, p, mm(TRACK_W))
    for kind, shape, net, clr, _ in obstacles:
        if net == netcode:
            continue
        if kind == "c":
            c, cr = shape
            if seg.Distance(c) < cr + hw + clr:
                return False
        elif shape.Collide(sshape, clr):
            return False
    return True


def add_via(p, net, lock):
    v = pcbnew.PCB_VIA(b)
    v.SetPosition(p)
    v.SetWidth(mm(VIA_D))
    v.SetDrill(mm(VIA_DRILL))
    v.SetNet(net)
    v.SetLocked(lock)
    b.Add(v)
    add_circle(p, mm(VIA_D / 2), net.GetNetCode())


def add_track(a, p, net, lock):
    t = pcbnew.PCB_TRACK(b)
    t.SetStart(a)
    t.SetEnd(p)
    t.SetWidth(mm(TRACK_W))
    t.SetLayer(pcbnew.F_Cu)
    t.SetNet(net)
    t.SetLocked(lock)
    b.Add(t)
    obstacles.append(("s", t.GetEffectiveShape(pcbnew.F_Cu), net.GetNetCode(), mm(CLR), False))


def fanout(netname):
    """Via + stub for every SMD pad on the net; fall back to a trace to nearby same-net copper."""
    net = b.FindNet(netname)
    nc = net.GetNetCode()
    vias, joined, misses = 0, [], []
    pads = sorted((pad for fp in b.GetFootprints() for pad in fp.Pads()
                   if pad.GetNetCode() == nc and not pad.HasHole() and pad.IsOnLayer(pcbnew.F_Cu)),
                  key=lambda q: (q.GetParentFootprint().GetReference(), q.GetNumber()))
    for pad in pads:
        c = pad.GetPosition()
        bb = pad.GetBoundingBox()
        half = max(bb.GetWidth(), bb.GetHeight()) / 2
        done = False
        for extra in (0.0, 0.15, 0.3, 0.5, 0.8, 1.1, 1.5, 2.0, 2.5):
            d = half + mm(VIA_D / 2 + CLR + extra)
            for k in range(24):
                a = 2 * math.pi * k / 24
                p = pcbnew.VECTOR2I(int(c.x + d * math.cos(a)), int(c.y + d * math.sin(a)))
                if via_ok(p, nc) and seg_ok(c, p, nc):
                    add_via(p, net, True)
                    add_track(c, p, net, True)
                    vias += 1
                    done = True
                    break
            if done:
                break
        if not done:
            targets = [q.GetPosition() for q in pads if q is not pad]
            targets += [t.GetPosition() for t in b.GetTracks()
                        if t.Type() == pcbnew.PCB_VIA_T and t.GetNetCode() == nc]
            targets.sort(key=lambda q: (q - c).EuclideanNorm())
            for q in targets:
                if (q - c).EuclideanNorm() > mm(5):
                    break
                if seg_ok(c, q, nc):
                    add_track(c, q, net, True)
                    joined.append(f"{pad.GetParentFootprint().GetReference()}.{pad.GetNumber()}")
                    done = True
                    break
        if not done:
            misses.append(f"{pad.GetParentFootprint().GetReference()}.{pad.GetNumber()}")
    return vias, joined, misses


def dangling_tracks(include_vias=False):
    b.BuildConnectivity()
    conn = b.GetConnectivity()
    kinds = (pcbnew.PCB_TRACE_T, pcbnew.PCB_VIA_T) if include_vias else (pcbnew.PCB_TRACE_T,)
    return [t for t in list(b.Tracks())
            if t.Type() in kinds and conn.TestTrackEndpointDangling(t, False)
            and not (t.Type() == pcbnew.PCB_VIA_T and t.GetNetname() in ("GND", "+3V3"))]


def end_is_free(t, end):
    """True if nothing else of the same net touches this trace end on its layer."""
    nc, layer = t.GetNetCode(), t.GetLayer()
    for fp in b.GetFootprints():
        for q in fp.Pads():
            if q.GetNetCode() == nc and q.IsOnLayer(layer) and q.HitTest(end, 0):
                return False
    for u in list(b.Tracks()):
        if u is t or u.GetNetCode() != nc:
            continue
        if u.Type() == pcbnew.PCB_VIA_T:
            if (u.GetPosition() - end).EuclideanNorm() <= u.GetWidth(layer) // 2:
                return False
        elif u.GetLayer() == layer and u.HitTest(end, 0):
            return False
    return True


def heal_layer_changes():
    """Freerouting sometimes drops a via where a trace changes layer. For each free trace
    end, find a via spot on the trace (sliding back from the end if it's crowded) and join
    it to the nearest same-net copper on the other layer."""
    healed = []
    for t in dangling_tracks():
        nc = t.GetNetCode()
        other = pcbnew.F_Cu if t.GetLayer() == pcbnew.B_Cu else pcbnew.B_Cu
        cands = [q.GetPosition() for fp in b.GetFootprints() for q in fp.Pads()
                 if q.GetNetCode() == nc and q.IsOnLayer(other)]
        cands += [e for u in list(b.Tracks()) if u.Type() == pcbnew.PCB_TRACE_T and u.GetNetCode() == nc
                  and u.GetLayer() == other for e in (u.GetStart(), u.GetEnd())]
        for end, far in ((t.GetStart(), t.GetEnd()), (t.GetEnd(), t.GetStart())):
            if not end_is_free(t, end):
                continue
            length = (far - end).EuclideanNorm()
            fixed = False
            for back_mm in (0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.3, 1.6, 2.0):
                if mm(back_mm) > length:
                    break
                f = mm(back_mm) / length if length else 0
                v = pcbnew.VECTOR2I(int(end.x + (far.x - end.x) * f), int(end.y + (far.y - end.y) * f))
                if not via_ok(v, nc):
                    continue
                near = sorted((q for q in cands if 0 < (q - v).EuclideanNorm() < mm(2.5)),
                              key=lambda q: (q - v).EuclideanNorm())
                for q in near:
                    if seg_ok(v, q, nc):
                        add_via(v, t.GetNet(), False)
                        tr = pcbnew.PCB_TRACK(b)
                        tr.SetStart(v)
                        tr.SetEnd(q)
                        tr.SetWidth(t.GetWidth())
                        tr.SetLayer(other)
                        tr.SetNet(t.GetNet())
                        b.Add(tr)
                        obstacles.append(("s", tr.GetEffectiveShape(other), nc, mm(CLR), False))
                        healed.append(t.GetNetname())
                        fixed = True
                        break
                if fixed:
                    break
    return healed


def remove_dangling():
    removed = 0
    for _ in range(10):
        stubs = dangling_tracks(include_vias=True)
        if not stubs:
            break
        for t in stubs:
            b.Delete(t)
        removed += len(stubs)
    return removed


def grid_stitch():
    gnd = b.FindNet("GND")
    step, n = mm(3.0), 0
    y = edge.GetTop() + mm(1.5)
    while y < edge.GetBottom():
        x = edge.GetLeft() + mm(1.5)
        while x < edge.GetRight():
            p = pcbnew.VECTOR2I(x, y)
            if via_ok(p, gnd.GetNetCode()):
                add_via(p, gnd, False)
                n += 1
            x += step
        y += step
    return n


mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode == "fanout":
    build_obstacles()
    for netname in ("+3V3", "GND"):
        v, j, m = fanout(netname)
        print(f"{netname}: {v} pad vias, joined by trace {j}, unresolved {m}")
elif mode == "finish":
    build_obstacles()
    healed = heal_layer_changes()
    print(f"healed dropped vias on: {healed}")
    n_dangling = remove_dangling()
    build_obstacles()
    n = grid_stitch()
    print(f"removed {n_dangling} dangling stubs; added {n} GND stitching vias")
else:
    raise SystemExit("usage: stitch.py fanout|finish")

pcbnew.ZONE_FILLER(b).Fill(b.Zones())
b.Save(PCB)
