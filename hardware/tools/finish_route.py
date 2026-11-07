"""Route the connections Freerouting left open, with a small grid A* router.

Reads the unconnected pairs from a kicad-cli DRC JSON report, then routes each on a
0.1 mm grid over F.Cu and B.Cu (inner layers are planes), using vias to change layer.
Other nets' copper, holes, the board edge and the antenna keep-out are blocked with
clearance. Repeats until nothing is left or no progress is made.

  python3 tools/finish_route.py      (run after `route.py import`, before `stitch.py finish`)
"""
import heapq
import json
import math
import subprocess

import numpy as np
import pcbnew

PCB = "/work/slidepod.kicad_pcb"
RES = 0.1                      # grid pitch, mm
CLR, HOLE_CLR, SLACK = 0.15, 0.25, 0.05
VIA_D, VIA_DRILL = 0.45, 0.2
VIA_COST = 15                  # in grid steps (1.5 mm)
POWER = {"VBUS", "VBAT", "VSYS", "VSYS_IN", "+3V3"}
LAYERS = (pcbnew.F_Cu, pcbnew.B_Cu)
mm = pcbnew.FromMM


def unconnected_pairs():
    subprocess.run(["kicad-cli", "pcb", "drc", "--format", "json", "-o", "/tmp/fr.json", PCB],
                   check=True, capture_output=True)
    d = json.load(open("/tmp/fr.json"))
    return [(i["items"][0]["uuid"], i["items"][1]["uuid"]) for i in d.get("unconnected_items", [])]


class Grid:
    def __init__(self, b, half_width):
        self.b = b
        e = b.GetBoardEdgesBoundingBox()
        self.x0, self.y0 = pcbnew.ToMM(e.GetLeft()), pcbnew.ToMM(e.GetTop())
        self.nx = int(round(pcbnew.ToMM(e.GetWidth()) / RES)) + 1
        self.ny = int(round(pcbnew.ToMM(e.GetHeight()) / RES)) + 1
        # owner[layer][iy, ix]: -1 free, >=0 only that net nearby, -2 blocked
        self.owner = [np.full((self.ny, self.nx), -1, dtype=np.int32) for _ in LAYERS]
        self.hw = half_width
        m = half_width + CLR + SLACK
        edge_m = 0.3 + half_width
        for o in self.owner:
            k = int(math.ceil(edge_m / RES))
            o[:k, :] = -2
            o[-k:, :] = -2
            o[:, :k] = -2
            o[:, -k:] = -2
        for fp in b.GetFootprints():
            for pad in fp.Pads():
                for li, layer in enumerate(LAYERS):
                    if pad.IsOnLayer(layer):
                        self.mark_shape(li, pad.GetEffectiveShape(layer), pad.GetBoundingBox(), pad.GetNetCode(), m)
                if pad.HasHole():
                    for li in range(2):
                        self.mark_shape(li, pad.GetEffectiveHoleShape(), pad.GetBoundingBox(), -2,
                                        half_width + HOLE_CLR + SLACK)
        for t in b.GetTracks():
            if t.Type() == pcbnew.PCB_VIA_T:
                c, r = t.GetPosition(), pcbnew.ToMM(t.GetWidth(pcbnew.F_Cu)) / 2
                for li in range(2):
                    self.mark_circle(li, c, r, t.GetNetCode(), m)
            else:
                for li, layer in enumerate(LAYERS):
                    if t.IsOnLayer(layer):
                        self.mark_seg(li, t.GetStart(), t.GetEnd(), pcbnew.ToMM(t.GetWidth()) / 2,
                                      t.GetNetCode(), m)
        areas = [z for z in b.Zones() if z.GetIsRuleArea()] + \
                [z for fp in b.GetFootprints() for z in fp.Zones() if z.GetIsRuleArea()]
        for z in areas:
            bb = z.GetBoundingBox()
            for li in range(2):
                for iy, ix, p in self.cells(bb, m):
                    if z.Outline().Collide(p, mm(m)):
                        self.owner[li][iy, ix] = -2

    def cells(self, bb, margin):
        ix0 = max(0, int((pcbnew.ToMM(bb.GetLeft()) - margin - self.x0) / RES) - 1)
        ix1 = min(self.nx - 1, int((pcbnew.ToMM(bb.GetRight()) + margin - self.x0) / RES) + 1)
        iy0 = max(0, int((pcbnew.ToMM(bb.GetTop()) - margin - self.y0) / RES) - 1)
        iy1 = min(self.ny - 1, int((pcbnew.ToMM(bb.GetBottom()) + margin - self.y0) / RES) + 1)
        for iy in range(iy0, iy1 + 1):
            for ix in range(ix0, ix1 + 1):
                yield iy, ix, self.pt(ix, iy)

    def pt(self, ix, iy):
        return pcbnew.VECTOR2I(mm(self.x0 + ix * RES), mm(self.y0 + iy * RES))

    def cell_of(self, p):
        return (int(round((pcbnew.ToMM(p.x) - self.x0) / RES)), int(round((pcbnew.ToMM(p.y) - self.y0) / RES)))

    def put(self, li, iy, ix, net):
        o = self.owner[li]
        cur = o[iy, ix]
        if cur == -2 or net == -2:
            o[iy, ix] = -2
        elif cur == -1:
            o[iy, ix] = net
        elif cur != net:
            o[iy, ix] = -2

    def mark_shape(self, li, shape, bb, net, margin):
        for iy, ix, p in self.cells(bb, margin):
            if shape.Collide(pcbnew.SEG(p, p), mm(margin)):
                self.put(li, iy, ix, net)

    def mark_circle(self, li, c, r, net, margin):
        bb = pcbnew.BOX2I(pcbnew.VECTOR2I(c.x - mm(r), c.y - mm(r)), pcbnew.VECTOR2L(mm(2 * r), mm(2 * r)))
        for iy, ix, p in self.cells(bb, margin):
            if (p - c).EuclideanNorm() <= mm(r + margin):
                self.put(li, iy, ix, net)

    def mark_seg(self, li, a, b, hw, net, margin):
        bb = pcbnew.BOX2I(pcbnew.VECTOR2I(min(a.x, b.x) - mm(hw), min(a.y, b.y) - mm(hw)),
                          pcbnew.VECTOR2L(abs(a.x - b.x) + mm(2 * hw), abs(a.y - b.y) + mm(2 * hw)))
        s = pcbnew.SEG(a, b)
        for iy, ix, p in self.cells(bb, margin):
            if s.Distance(p) <= mm(hw + margin):
                self.put(li, iy, ix, net)

    def free(self, li, ix, iy, net):
        if not (0 <= ix < self.nx and 0 <= iy < self.ny):
            return False
        o = self.owner[li][iy, ix]
        return o == -1 or o == net

    def via_ok(self, ix, iy, net):
        # Via radius + clearance exceeds the track margin by ~0.15 mm: require a free
        # 5x5 neighbourhood (+-0.2 mm) on both layers.
        for li in range(2):
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    if not self.free(li, ix + dx, iy + dy, net):
                        return False
        return True


def item_index(b):
    idx = {t.m_Uuid.AsString(): t for t in b.GetTracks()}
    for fp in b.GetFootprints():
        for pad in fp.Pads():
            idx[pad.m_Uuid.AsString()] = pad
    return idx


def endpoints(item, other_pos):
    """Candidate (position, layers) to route from/to on this item, best first."""
    if item is None:
        return []
    if item.Type() == pcbnew.PCB_PAD_T:
        return [(item.GetPosition(), [li for li, l in enumerate(LAYERS) if item.IsOnLayer(l)])]
    if item.Type() == pcbnew.PCB_VIA_T:
        return [(item.GetPosition(), [0, 1])]
    if item.Type() == pcbnew.PCB_TRACE_T:
        ends = sorted((item.GetStart(), item.GetEnd()), key=lambda q: (q - other_pos).EuclideanNorm())
        li = 0 if item.GetLayer() == pcbnew.F_Cu else 1
        return [(e, [li]) for e in ends]
    return []


def astar(g, net, start, s_layers, goal, g_layers):
    sx, sy = g.cell_of(start)
    gx, gy = g.cell_of(goal)
    goals = {(li, gx, gy) for li in g_layers}

    def h(ix, iy):
        dx, dy = abs(ix - gx), abs(iy - gy)
        return max(dx, dy) + 0.414 * min(dx, dy)

    openh, best, came = [], {}, {}
    for li in s_layers:
        st = (li, sx, sy)
        best[st] = 0
        heapq.heappush(openh, (h(sx, sy), 0, st))
    steps = 0
    while openh and steps < 3_000_000:
        f, cost, st = heapq.heappop(openh)
        if cost > best.get(st, 1e18):
            continue
        if st in goals:
            path = [st]
            while path[-1] in came:
                path.append(came[path[-1]])
            return path[::-1]
        steps += 1
        li, ix, iy = st
        moves = []
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            nx_, ny_ = ix + dx, iy + dy
            n = (li, nx_, ny_)
            if g.free(li, nx_, ny_, net) or n in goals:
                if dx and dy and not (g.free(li, ix + dx, iy, net) and g.free(li, ix, iy + dy, net)):
                    continue  # no corner cutting
                moves.append((n, 1.414 if dx and dy else 1.0))
        if g.via_ok(ix, iy, net):
            moves.append(((1 - li, ix, iy), VIA_COST))
        for n, c in moves:
            nc = cost + c
            if nc < best.get(n, 1e18):
                best[n] = nc
                came[n] = st
                heapq.heappush(openh, (nc + h(n[1], n[2]), nc, n))
    return None


def commit(b, g, net_code, path, start, goal, width):
    net = b.FindNet(b.GetNetInfo().GetNetItem(net_code).GetNetname())
    pts = [(li, g.pt(ix, iy)) for li, ix, iy in path]
    pts[0] = (pts[0][0], start)
    pts[-1] = (pts[-1][0], goal)
    # collapse straight runs
    simp = [pts[0]]
    for i in range(1, len(pts) - 1):
        (l0, a), (l1, p), (l2, c) = simp[-1], pts[i], pts[i + 1]
        if l1 != l0 or l1 != l2:
            simp.append(pts[i])
            continue
        d1 = (p.x - a.x, p.y - a.y)
        d2 = (c.x - p.x, c.y - p.y)
        if d1[0] * d2[1] - d1[1] * d2[0] != 0 or d1[0] * d2[0] + d1[1] * d2[1] < 0:
            simp.append(pts[i])
    simp.append(pts[-1])
    n_tracks = n_vias = 0
    for (la, a), (lb, p) in zip(simp, simp[1:]):
        if la != lb:
            if any(t.Type() == pcbnew.PCB_VIA_T and t.GetNetCode() == net_code
                   and (t.GetPosition() - p).EuclideanNorm() < mm(0.05) for t in b.GetTracks()):
                continue  # a via is already there
            v = pcbnew.PCB_VIA(b)
            v.SetPosition(p)
            v.SetWidth(mm(VIA_D))
            v.SetDrill(mm(VIA_DRILL))
            v.SetNet(net)
            b.Add(v)
            n_vias += 1
            continue
        if a == p:
            continue
        t = pcbnew.PCB_TRACK(b)
        t.SetStart(a)
        t.SetEnd(p)
        t.SetWidth(mm(width))
        t.SetLayer(LAYERS[la])
        t.SetNet(net)
        b.Add(t)
        n_tracks += 1
    return n_tracks, n_vias


def main():
    done, failed = [], []
    for _ in range(12):
        pairs = unconnected_pairs()
        b = pcbnew.LoadBoard(PCB)
        b.BuildConnectivity()
        idx = item_index(b)
        todo = []
        for ua, ub in pairs:
            ia, ib = idx.get(ua), idx.get(ub)
            if ia is None or ib is None:
                continue
            if ia.GetNetCode() == ib.GetNetCode() and ia.GetNetname() != "GND":
                # Besides the two reported items, any pad in either island will do.
                conn = b.GetConnectivity()

                def island(item, other):
                    c = endpoints(item, other.GetPosition())
                    try:
                        pads = list(conn.GetConnectedPads(item))
                    except Exception:
                        pads = []
                    pads.sort(key=lambda q: (q.GetPosition() - other.GetPosition()).EuclideanNorm())
                    return c + [x for q in pads for x in endpoints(q, other.GetPosition())]
                todo.append((ia.GetNetname(), ia.GetNetCode(), (ua, ub), island(ia, ib), island(ib, ia)))
        todo = [t for t in todo if t[2] not in failed]
        if not todo:
            break
        name, nc, key, ca, cb = todo[0]
        width = 0.3 if name in POWER else 0.15
        g = Grid(b, width / 2)
        path = None
        # try every endpoint combination, in both directions
        for (a, la) in ca:
            for (bpos, lb) in cb:
                for (p0, l0, p1, l1) in ((a, la, bpos, lb), (bpos, lb, a, la)):
                    path = astar(g, nc, p0, l0, p1, l1)
                    if path:
                        a, bpos = p0, p1
                        break
                if path:
                    break
            if path:
                break
        if path is None:
            failed.append(key)
            print(f"  {name}: no path")
            continue
        nt, nv = commit(b, g, nc, path, a, bpos, width)
        pcbnew.ZONE_FILLER(b).Fill(b.Zones())
        b.Save(PCB)
        done.append(name)
        print(f"  {name}: {nt} tracks, {nv} vias")
    print(f"finish_route: routed {done}; failed {[f[0] for f in failed]}; "
          f"left unconnected: {len(unconnected_pairs())}")


if __name__ == "__main__":
    main()
