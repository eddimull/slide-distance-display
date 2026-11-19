"""SlidePod cradle mount generator for Autodesk Fusion.

Run as a Fusion script (Utilities > Scripts, or via the Fusion MCP). Creates a new
design document containing the mount plus reference bodies (tube, brace, PCB,
battery) so fit can be checked visually. Edit P and re-run to regenerate.

Coordinate frame (mm):
  Z = slide axis, +Z points from the inner brace toward the outer slide crossbar
      (the direction the ToF sensor looks). Brace front face is z = 0.
  Y = up, toward the upper (lead-pipe) tube. Tube centreline is at x = 0, y = 0.
  X = across the slide plane. Sensor is centred at x = 0, in line with brace/crossbar.

The PCB stands upright, components facing +Z, antenna (PCB y=100 edge) down.
PCB-to-world mapping (KiCad coords):  X = pcb_x - 115,  Y = -SENSOR_DROP + (pcb_y - 130.5)
"""
import math

import adsk.core
import adsk.fusion

P = dict(
    TUBE_D=22.0,        # upper (lead-pipe) tube OD
    BRACE_D=13.0,       # inner slide brace (handle) OD
    SADDLE_CLR=0.2,     # radial clearance on both saddles
    SENSOR_DROP=32.0,   # tube centreline -> sensor centre (Y)
    BOARD_W=30.0, BOARD_H=50.0, BOARD_T=1.6,
    BAT_W=25.0, BAT_H=35.0, BAT_T=5.15,
    BAT_FIT=0.3,        # clearance per side around battery
    BAT_WIRE=0.4,       # extra pocket length at the lead (top) end -> 36.0 mm pocket
    WIRE_CH_W=2.0,     # battery lead channel width (Y), past the top of the pocket
    WIRE_CH_L=8.0,      # how far the channel reaches in from the pocket's side edge
    BAT_GAP=0.35,       # extra depth above battery
    BOARD_FIT=0.25,     # clearance per side around PCB
    FLOOR=2.0,          # behind-battery floor thickness
    WALL=1.6,
    LIP=1.5,            # wall height above PCB top surface
    # board retention: fixed lip on the top (tube) wall, flexing snaps on the bottom wall
    TOP_LIP=0.8,        # fixed lip overhang onto PCB at top edge
    SNAP_X=11.5,        # |x| of the two bottom snap fingers (clear of ESP32 module +/-7.7)
    SNAP_W=6.0,         # finger width
    SNAP_HOOK=0.8,      # hook overhang onto PCB
    SNAP_FLAT=0.4,      # vertical catch face height before the 45 deg lead-in
    SNAP_SLIT=0.8,     # side slit width freeing the finger
    SNAP_GAP=0.6,       # gap separating finger from the ledge behind it
    SNAP_ROOT=1.0,      # finger is anchored to the floor below this z
    # slide switch access
    SW_NOTCH_H=12.0,    # notch length along the wall
    SW_RELIEF_R=4.0,    # radius of the outside finger scoop
    TUBE_HORN_T=2.3,    # saddle horn thickness at the tube
    TUBE_HORN_TOP=-4.0, # Y of horn tips
    SADDLE_EXT=10.0,    # tube saddle extension forward (+Z) past the tray rim (L shape);
                        # ~22 mm of bare tube before the slide lock, so keep z_top+EXT < ~20
    SADDLE_FLOOR=2.0,   # material under the tube in the extension
    BRACE_RAIL_W=17.0,  # width of rear brace saddle block
    BRACE_RAIL_D=3.5,   # depth of rear brace saddle block
    PEG_R=2.5, PEG_L=4.0, PEG_HEAD_R=3.5, PEG_HEAD_L=1.0,
    ANCHOR='bands',     # 'bands' = rubber band pegs, 'velcro' = strap slot ears,
                        # 'clamp' = screw-down V cap on the top tube (needs SADDLE='v')
    # velcro strap ears (ANCHOR='velcro')
    STRAP_W=13.0,       # slot length, fits ~12 mm hook-and-loop straps
    STRAP_T=2.5,        # slot width (strap thickness + clearance)
    EAR_BAR=2.0,        # thickness of the bar outside / caps around each slot
    # saddle shape: 'round' = cylinder cut sized to TUBE_D/BRACE_D,
    # 'v' = flat-bottomed V-grooves that self-centre a range of tube sizes
    SADDLE='round',
    V_ANGLE=120.0,      # included angle of both V-grooves
    LINER_T=0.0,        # foam/silicone liner thickness, so the nominal tube still sits centred
    # screw-down cap (ANCHOR='clamp'): 2x M3 screws through side ears, nuts slide into
    # side-entry slots in the base ears. Gap between ears sets the tube-size range:
    # it shrinks 1.15 mm per mm of smaller tube, so 3 mm -> down to ~19.4 mm tube.
    CLAMP_GAP=3.0,      # gap between cap ears and base ears with the nominal tube
    CAP_T=2.5,          # cap material over the tube
    CAP_EAR_T=4.0,      # cap ear thickness (screw head seats on top)
    CLAMP_EAR_W=7.0,    # ear width outboard of the saddle horn
    SCREW_INSET=3.5,    # screw axis distance outboard of the horn face
    SCREW_HOLE_D=3.4,   # M3 clearance
    NUT_AF=5.7,         # M3 nut across-flats + clearance (slot width)
    NUT_T=2.6,          # M3 nut thickness + clearance (slot height)
    NUT_COVER=1.7,      # material between base ear top and nut slot
    BRACE_CLAMP=True,   # ANCHOR='clamp': also clamp the brace with a back cap
    BRACE_CAP_L=12.0,   # back cap length along the brace (sits at the antenna end)
    FILLET_R=0.6,       # round convex outside edges (0 = leave sharp); board pocket,
                        # lips, snap hooks and slits are left sharp on purpose
)

# Named variants: overrides applied on top of P. Set MODE (or ns['MODE'] when exec'd).
VARIANTS = {
    'bands': {},
    # top strap wraps tube + saddle through slots in ears on the saddle extension,
    # so the extension must be at least STRAP_W + 2*EAR_BAR long
    'velcro': {'ANCHOR': 'velcro', 'SADDLE_EXT': 18.0},
    'bands_v': {'SADDLE': 'v'},
    'velcro_v': {'ANCHOR': 'velcro', 'SADDLE_EXT': 18.0, 'SADDLE': 'v'},
    'clamp': {'ANCHOR': 'clamp', 'SADDLE': 'v'},
}
MODE = 'bands'


def _convex_edges(body, keep_sharp):
    """Convex edges between two planar faces, keyed by rounded midpoint (mm)."""
    PLANE = adsk.core.SurfaceTypes.PlaneSurfaceType
    OUT = adsk.fusion.PointContainment.PointOutsidePointContainment
    found = {}
    for e in body.edges:
        if e.faces.count != 2 or any(fc.geometry.surfaceType != PLANE for fc in e.faces):
            continue
        ev = e.evaluator
        _, t0, t1 = ev.getParameterExtents()
        _, length = ev.getLengthAtParameter(t0, t1)
        if length < 0.1:                                   # < 1 mm
            continue
        _, m = ev.getPointAtParameter((t0 + t1) / 2)
        if keep_sharp(m.x * 10, m.y * 10, m.z * 10):
            continue
        _, n1 = e.faces.item(0).evaluator.getNormalAtPoint(m)
        _, n2 = e.faces.item(1).evaluator.getNormalAtPoint(m)
        d = n1.copy()
        d.subtract(n2)
        if d.length < 1e-6:
            continue
        d.normalize()
        d.scaleBy(0.005)                                   # 0.05 mm probe
        q = m.copy()
        q.translateBy(d)
        if body.pointContainment(q) == OUT:                # convex edge
            found[(round(m.x * 100), round(m.y * 100), round(m.z * 100))] = e
    return found


def fillet_outside(design, root, name, r_mm, keep_sharp):
    """Fillet convex outside edges; groups that fail are split until the offending
    edges are isolated and skipped."""
    fillets = root.features.filletFeatures
    skip = set()
    stats = {'ok': 0, 'skipped': 0}

    def attempt(keys):
        body = root.bRepBodies.itemByName(name)
        cur = _convex_edges(body, keep_sharp)
        edges = adsk.core.ObjectCollection.create()
        for k in keys:
            if k in cur:
                edges.add(cur[k])
        if edges.count == 0:
            return True
        fi = fillets.createInput()
        fi.edgeSetInputs.addConstantRadiusEdgeSet(
            edges, adsk.core.ValueInput.createByReal(r_mm / 10), False)
        try:
            feat = fillets.add(fi)
        except RuntimeError:
            return False
        if feat.healthState != adsk.fusion.FeatureHealthStates.HealthyFeatureHealthState:
            feat.deleteMe()
            return False
        stats['ok'] += edges.count
        return True

    def solve(keys):
        if attempt(keys):
            return
        if len(keys) == 1:
            skip.add(keys[0])
            stats['skipped'] += 1
            return
        h = len(keys) // 2
        solve(keys[:h])
        solve(keys[h:])

    for _ in range(4):        # edges shortened by neighbouring fillets get new keys
        keys = sorted(set(_convex_edges(root.bRepBodies.itemByName(name), keep_sharp)) - skip)
        if not keys:
            break
        solve(keys)
    print('%s: filleted %d edges, skipped %d' % (name, stats['ok'], stats['skipped']))


def run(_context: str):
    p = dict(P, **VARIANTS[MODE])
    app = adsk.core.Application.get()
    design = adsk.fusion.Design.cast(app.activeProduct)
    # reuse an empty, never-saved document; otherwise start a fresh one
    if design is None or app.activeDocument.isSaved or design.timeline.count > 0:
        app.documents.add(adsk.core.DocumentTypes.FusionDesignDocumentType)
        design = adsk.fusion.Design.cast(app.activeProduct)
    design.designType = adsk.fusion.DesignTypes.ParametricDesignType
    root = design.rootComponent
    tb = adsk.fusion.TemporaryBRepManager.get()
    UNION = adsk.fusion.BooleanTypes.UnionBooleanType
    DIFF = adsk.fusion.BooleanTypes.DifferenceBooleanType
    INTER = adsk.fusion.BooleanTypes.IntersectionBooleanType

    def pt(x, y, z):
        return adsk.core.Point3D.create(x / 10, y / 10, z / 10)

    def box(x0, x1, y0, y1, z0, z1):
        obb = adsk.core.OrientedBoundingBox3D.create(
            pt((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
            adsk.core.Vector3D.create(1, 0, 0), adsk.core.Vector3D.create(0, 1, 0),
            abs(x1 - x0) / 10, abs(y1 - y0) / 10, abs(z1 - z0) / 10)
        return tb.createBox(obb)

    def cyl(a, b, r):
        return tb.createCylinderOrCone(pt(*a), r / 10, pt(*b), r / 10)

    def add(t, o):
        tb.booleanOperation(t, o, UNION)

    def sub(t, o):
        tb.booleanOperation(t, o, DIFF)

    def vadd(*vs):
        return tuple(sum(c) for c in zip(*vs))

    def vmul(v, k):
        return tuple(c * k for c in v)

    def cross(u, v):
        return (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])

    def rbox(center, ldir, wdir, l, w, h):
        return tb.createBox(adsk.core.OrientedBoundingBox3D.create(
            pt(*center), adsk.core.Vector3D.create(*ldir), adsk.core.Vector3D.create(*wdir),
            l / 10, w / 10, h / 10))

    def vee_cut(apex, axis, opening, flat_dist, lo, hi, size=80.0, width=None, target=None):
        """Cut a V-groove running along `axis` (unit), apex at `apex` (axis component 0),
        opening toward `opening` (unit, perpendicular to axis), truncated by a flat
        `flat_dist` from the apex. Groove spans axis coordinate lo..hi."""
        side = cross(axis, opening)
        mid = vmul(axis, (lo + hi) / 2)
        groove = None
        for s in (1, -1):
            u = vadd(vmul(side, s * sa), vmul(opening, ca))       # along the V face
            n = vadd(vmul(side, -s * ca), vmul(opening, sa))      # face normal, into the groove
            half = rbox(vadd(apex, mid, vmul(n, size / 2)), u, n, 2 * size, size, hi - lo)
            if groove is None:
                groove = half
            else:
                tb.booleanOperation(groove, half, INTER)
        sub(groove, rbox(vadd(apex, mid, vmul(opening, max(flat_dist, 0) - size / 2)),
                        side, opening, 2 * size, size, hi - lo))
        if width is not None:   # keep the groove within +/- width of the centreline
            tb.booleanOperation(groove, rbox(vadd(apex, mid, vmul(opening, size / 2)),
                                             side, opening, 2 * width, size, hi - lo), INTER)
        sub(target or body, groove)

    # --- key levels -------------------------------------------------------
    tube_r = p['TUBE_D'] / 2
    brace_r = p['BRACE_D'] / 2
    z_board = p['FLOOR'] + p['BAT_T'] + p['BAT_GAP']          # PCB back face
    z_top = z_board + p['BOARD_T'] + p['LIP']                  # tray rim

    def W(px, py):  # KiCad -> world XY (viewed from the component side, antenna down)
        # KiCad Y points down the screen, so a 180 deg in-plane rotation that puts the
        # antenna (pcb y=100) at the bottom flips X but keeps +pcb_y as +world Y.
        return 115.0 - px, -p['SENSOR_DROP'] + (py - 130.5)

    (ax, ay), (bx, by) = W(100, 100), W(130, 150)
    bx0, bx1 = min(ax, bx), max(ax, bx)
    by0, by1 = min(ay, by), max(ay, by)
    f = p['BOARD_FIT']
    px0, px1, py0, py1 = bx0 - f, bx1 + f, by0 - f, by1 + f     # board pocket
    ox0, ox1 = px0 - p['WALL'], px1 + p['WALL']
    oy0, oy1 = py0 - p['WALL'], py1 + p['WALL']
    bcx, bcy = (bx0 + bx1) / 2, (by0 + by1) / 2

    # --- tray -------------------------------------------------------------
    body = box(ox0, ox1, oy0, oy1, 0, z_top)
    sub(body, box(px0, px1, py0, py1, z_board, z_top + 1))
    bf = p['BAT_FIT']
    # battery leads exit at the top (+Y, tube) end, so the extra length goes there
    bat_x0, bat_x1 = bcx - p['BAT_W'] / 2 - bf, bcx + p['BAT_W'] / 2 + bf
    bat_y0 = bcy - p['BAT_H'] / 2 - bf
    bat_y1 = bcy + p['BAT_H'] / 2 + bf + p['BAT_WIRE']
    sub(body, box(bat_x0, bat_x1, bat_y0, bat_y1, p['FLOOR'], z_board + 0.01))

    # --- saddle shape ------------------------------------------------------
    hx = tube_r + p['SADDLE_CLR'] + p['TUBE_HORN_T']
    vee = p['SADDLE'] == 'v'
    horn_top = p['TUBE_HORN_TOP']
    if vee:
        # V faces touch any round tube; a nominal tube (plus liner) touches them with its
        # centre exactly where the round saddle put it, so the sensor aim is unchanged.
        # Size changes only translate the mount (tube V runs along the slide axis, brace V
        # is symmetric in X), they don't tilt the sensor.
        a = math.radians(p['V_ANGLE'] / 2)
        sa, ca, ta = math.sin(a), math.cos(a), math.tan(a)
        lin = p['LINER_T']
        tube_apex = -(tube_r + lin) / sa                       # Y of tube V apex
        tube_flat = -(tube_r + p['SADDLE_CLR'] + lin)          # flat floor, clear of nominal
        brace_apex = -(brace_r + p['SADDLE_CLR']) + (brace_r + lin) / sa   # Z of brace V apex
        horn_top = min(horn_top, tube_apex + (hx - 1.0) / ta)  # leave a 1 mm land on the horn

    # --- tube saddle horns (top) -----------------------------------------
    add(body, box(-hx, hx, oy1 - 0.5, horn_top, 0, z_top))
    # forward extension along the tube (side view: L with the tray)
    ext_y0 = -(tube_r + p['SADDLE_CLR'] + p['SADDLE_FLOOR'])
    add(body, box(-hx, hx, ext_y0, horn_top, z_top - 0.01, z_top + p['SADDLE_EXT']))

    # --- brace saddle rail (back) ----------------------------------------
    rw = p['BRACE_RAIL_W'] / 2
    add(body, box(-rw, rw, oy0, horn_top, -p['BRACE_RAIL_D'], 0.01))
    if vee:   # groove opens toward -Z (the brace); flat floor at the tray back, z = 0
        vee_cut((0, 0, brace_apex), (0, 1, 0), (0, 0, -1), brace_apex, oy0 - 5, 5, width=rw)
    else:
        bz = -(brace_r + p['SADDLE_CLR'])
        sub(body, cyl((0, oy0 - 5, bz), (0, 5, bz), brace_r + p['SADDLE_CLR']))

    # --- rubber band pegs -------------------------------------------------
    peg_z = z_top / 2
    top_peg_z = z_top + p['SADDLE_EXT'] - p['PEG_HEAD_R']    # at the end of the saddle extension
    top_peg_y = (oy1 + horn_top) / 2
    peg_spots = [(hx, top_peg_y, top_peg_z, 1), (-hx, top_peg_y, top_peg_z, -1),
                 (ox1, oy0 + 6.5, peg_z, 1), (ox0, oy0 + 6.5, peg_z, -1)]
    cap = bcap = None
    rw = p['BRACE_RAIL_W'] / 2
    if p['ANCHOR'] == 'clamp':
        assert vee, "ANCHOR='clamp' needs SADDLE='v'"
        g2 = p['CLAMP_GAP'] / 2
        z0c, z1c = 0.0, z_top + p['SADDLE_EXT']        # cap covers the whole tube saddle
        zs = (z0c + z1c) / 2                            # one screw per side, mid-length
        ew = p['CLAMP_EAR_W']
        sx = hx + p['SCREW_INSET']
        nut_y1 = -g2 - p['NUT_COVER']
        nut_y0 = nut_y1 - p['NUT_T']
        base_ear_y0 = oy1 - 0.5
        cap_top = -tube_flat + p['CAP_T']
        cap_ear_y1 = g2 + p['CAP_EAR_T']
        cap = box(-hx, hx, g2, cap_top, z0c, z1c)
        for s in (1, -1):
            xa, xb = sorted((s * (hx - 0.01), s * (hx + ew)))
            add(body, box(xa, xb, base_ear_y0, -g2, z0c, z1c))
            add(cap, box(xa, xb, g2, cap_ear_y1, z0c, z1c))
            # side-entry nut slot, open to the outside face of the base ear
            xa, xb = sorted((s * sx, s * (hx + ew + 1)))
            sub(body, box(xa, xb, nut_y0, nut_y1, zs - p['NUT_AF'] / 2, zs + p['NUT_AF'] / 2))
            hr = p['SCREW_HOLE_D'] / 2
            sub(body, cyl((s * sx, base_ear_y0 + 0.75, zs), (s * sx, 1, zs), hr))
            sub(cap, cyl((s * sx, -1, zs), (s * sx, cap_ear_y1 + 1, zs), hr))
        # cap V opens down onto the tube, mirror of the base groove
        vee_cut((0, -tube_apex, 0), (0, 0, 1), (0, -1, 0), tube_flat - tube_apex,
                z0c - 1, z1c + 1, width=hx, target=cap)

        if p['BRACE_CLAMP']:
            # back cap over the brace. Screws run along Z at the antenna end, where the
            # tray is solid between the snap-finger gap and the battery pocket, so the
            # nuts (side-entry slots in the side walls) and screw tips sit in the tray.
            bzc = -(brace_r + p['SADDLE_CLR'])                 # nominal brace centre z
            ys = (py0 + p['SNAP_GAP'] + bat_y0) / 2            # screw height
            by0c = oy0
            by1c = max(ys + (ys - oy0), ys + p['BRACE_CAP_L'] / 2)
            sxb = rw + p['SCREW_INSET']
            hr = p['SCREW_HOLE_D'] / 2
            b_ear_z0 = bzc + g2                                # back face of base ears
            cap_ear_z1 = bzc - g2                              # front face of cap ears
            cap_ear_z0 = cap_ear_z1 - p['CAP_EAR_T']
            bcap_back = bzc - (brace_r + p['SADDLE_CLR']) - p['CAP_T']
            bcap = box(-rw, rw, by0c, by1c, bcap_back, cap_ear_z1)
            nz0 = b_ear_z0 + p['NUT_COVER'] + 1.5              # nut slot spans the tray back
            for s in (1, -1):
                xa, xb = sorted((s * (rw - 0.01), s * ox1 if s > 0 else ox0))
                add(body, box(xa, xb, by0c, by1c, b_ear_z0, 0.01))
                add(bcap, box(xa, xb, by0c, by1c, cap_ear_z0, cap_ear_z1))
                xa, xb = sorted((s * sxb, s * (ox1 + 1)))
                sub(body, box(xa, xb, ys - p['NUT_AF'] / 2, ys + p['NUT_AF'] / 2,
                              nz0, nz0 + p['NUT_T']))
                sub(body, cyl((s * sxb, ys, b_ear_z0 - 1), (s * sxb, ys, z_board - 0.5), hr))
                sub(bcap, cyl((s * sxb, ys, cap_ear_z0 - 1), (s * sxb, ys, cap_ear_z1 + 1), hr))
            bcap_apex = bzc - (brace_r + lin) / sa
            vee_cut((0, 0, bcap_apex), (0, 1, 0), (0, 0, 1),
                    (bzc - (brace_r + p['SADDLE_CLR'])) - bcap_apex,
                    by0c - 1, by1c + 1, width=rw, target=bcap)
            print('brace clamp: screws at y=%.1f x=+/-%.1f, cap y %.1f..%.1f' % (ys, sxb, by0c, by1c))
    elif p['ANCHOR'] == 'bands':
        for x, y, pz, s in peg_spots:
            x1 = x + s * p['PEG_L']
            add(body, cyl((x - s * 0.5, y, pz), (x1, y, pz), p['PEG_R']))
            add(body, cyl((x1, y, pz), (x1 + s * p['PEG_HEAD_L'], y, pz), p['PEG_HEAD_R']))
    else:
        sw_, st_, eb = p['STRAP_W'], p['STRAP_T'], p['EAR_BAR']
        # top ears on the saddle extension; slot runs vertically (Y) so the strap
        # goes over the tube, down through one ear, under the saddle, up the other
        zc = z_top + p['SADDLE_EXT'] / 2
        for s in (1, -1):
            xa, xb = sorted((s * (hx - 0.01), s * (hx + st_ + eb)))
            add(body, box(xa, xb, ext_y0, horn_top, z_top - 0.01, z_top + p['SADDLE_EXT']))
            xa, xb = sorted((s * hx, s * (hx + st_)))
            sub(body, box(xa, xb, ext_y0 - 1, horn_top + 1, zc - sw_ / 2, zc + sw_ / 2))
        # bottom ears on the side walls; slot runs front-to-back (Z) so the strap goes
        # around the back of the brace and closes across the front of the antenna end
        for s, ox in ((1, ox1), (-1, ox0)):
            xa, xb = sorted((ox - s * 0.01, ox + s * (st_ + eb)))
            add(body, box(xa, xb, oy0, oy0 + sw_ + 2 * eb, 0, z_top))
            xa, xb = sorted((ox, ox + s * st_))
            sub(body, box(xa, xb, oy0 + eb, oy0 + eb + sw_, -1, z_top + 1))

    # --- connector / switch cutouts --------------------------------------
    def side_cut(x_part, y0, y1, z0, z1):
        """Cut through whichever side wall is nearest the part at x_part."""
        if x_part > 0:
            sub(body, box(px1 - 0.01, ox1 + 1, y0, y1, z0, z1))
        else:
            sub(body, box(ox0 - 1, px0 + 0.01, y0, y1, z0, z1))

    usb_x, usb_y = W(104.2, 134.6)       # J1 USB-C, mouth on the PCB x=100 edge
    side_cut(usb_x, usb_y - 5.5, usb_y + 5.5, z_board - 1.5, z_top + 1)
    sw_x, sw_y = W(128.2, 145.3)         # SW3 slide switch, PCB x=130 edge
    swh = p['SW_NOTCH_H'] / 2
    side_cut(sw_x, sw_y - swh, sw_y + swh, z_board, z_top + 1)
    swz = z_board + p['BOARD_T'] + 1.2   # finger scoop centred near the actuator
    scoop_x = ox1 + 0.5 if sw_x > 0 else ox0 - 0.5
    sub(body, cyl((scoop_x, sw_y - swh, swz), (scoop_x, sw_y + swh, swz), p['SW_RELIEF_R']))
    jst_x, jst_y = W(125, 136)           # J2 battery JST, PCB x=130 edge: plug opening
    side_cut(jst_x, jst_y - 4.5, jst_y + 4.5, z_board - 1.5, z_top + 1)
    # battery lead channel: leaves the top end of the battery pocket on the JST side,
    # runs under the board to the side wall and exits there; leads loop to the plug.
    ch_y0, ch_y1 = bat_y1 - 0.01, bat_y1 + p['WIRE_CH_W']
    if jst_x > 0:
        sub(body, box(bat_x1 - p['WIRE_CH_L'], px1 + 0.01, ch_y0, ch_y1, p['FLOOR'], z_board + 0.01))
    else:
        sub(body, box(px0 - 0.01, bat_x0 + p['WIRE_CH_L'], ch_y0, ch_y1, p['FLOOR'], z_board + 0.01))
    side_cut(jst_x, ch_y0, ch_y1, p['FLOOR'], z_board + 0.01)
    j3_x, j3_y = W(113.2, 148.4)         # J3 solder wires, top edge
    sub(body, box(j3_x - 2.5, j3_x + 2.5, py1 - 0.01, oy1 + 1, z_board, z_top + 1))

    # --- board retention --------------------------------------------------
    z_hook = z_board + p['BOARD_T'] + 0.1      # underside of lips/hooks
    # fixed top lip, two segments clear of the J3 notch and the tube-thinned centre
    keep_out = sorted([(j3_x - 3.0, j3_x + 3.0), (sw_x - 3.0, sw_x + 3.0)])
    edges = [px0 + 1.0] + [v for ko in keep_out for v in ko] + [px1 - 1.0]
    for lx0, lx1 in zip(edges[0::2], edges[1::2]):
        lx0, lx1 = max(lx0, px0 + 1.0), min(lx1, px1 - 1.0)
        if lx1 - lx0 > 2.0:
            add(body, box(lx0, lx1, py1 - p['TOP_LIP'], py1 + 0.01, z_hook, z_top))
    # flexing snap fingers in the bottom wall
    n = 2 ** -0.5
    for c in (-p['SNAP_X'], p['SNAP_X']):
        hw = p['SNAP_W'] / 2
        s = p['SNAP_SLIT']
        for sx in (c - hw - s, c + hw):                       # side slits
            sub(body, box(sx, sx + s, oy0 - 1, py0 + p['SNAP_GAP'], p['SNAP_ROOT'], z_top + 1))
        sub(body, box(c - hw - s, c + hw + s, py0 - 0.01, py0 + p['SNAP_GAP'],
                      p['SNAP_ROOT'], z_board + 0.01))         # free finger from ledge
        add(body, box(c - hw, c + hw, py0 - 0.01, py0 + p['SNAP_HOOK'], z_hook, z_top))
        # 45 deg lead-in on the hook: remove everything above a plane through Q
        q = (py0 + p['SNAP_HOOK'], z_hook + p['SNAP_FLAT'])
        h = 6.0
        obb = adsk.core.OrientedBoundingBox3D.create(
            pt(c, q[0] + n * h / 2, q[1] + n * h / 2),
            adsk.core.Vector3D.create(1, 0, 0), adsk.core.Vector3D.create(0, -n, n),
            (p['SNAP_W'] + 0.02) / 10, 10 / 10, h / 10)
        sub(body, tb.createBox(obb))

    # --- tube cut last (shapes the top saddle) ---------------------------
    if vee:
        vee_cut((0, tube_apex, 0), (0, 0, 1), (0, 1, 0), tube_flat - tube_apex, -20, z_top + 40,
                width=hx)
    else:
        sub(body, cyl((0, 0, -20), (0, 0, z_top + 20), tube_r + p['SADDLE_CLR']))

    # --- reference bodies -------------------------------------------------
    refs = {
        'REF tube': cyl((0, 0, -15), (0, 0, 40), tube_r),
        'REF brace': cyl((0, oy0 - 10, -brace_r), (0, 0, -brace_r), brace_r),
        'REF pcb': box(bx0, bx1, by0, by1, z_board, z_board + p['BOARD_T']),
        'REF battery': box(bcx - p['BAT_W'] / 2, bcx + p['BAT_W'] / 2,
                           bcy - p['BAT_H'] / 2, bcy + p['BAT_H'] / 2,
                           p['FLOOR'] + 0.1, p['FLOOR'] + 0.1 + p['BAT_T']),
        'REF sensor axis': cyl((0, -p['SENSOR_DROP'], z_board + p['BOARD_T']),
                               (0, -p['SENSOR_DROP'], 52), 0.4),
    }

    base = root.features.baseFeatures.add()
    base.startEdit()
    mb = root.bRepBodies.add(body, base)
    mb.name = 'SlidePod Mount'
    if cap is not None:
        root.bRepBodies.add(cap, base).name = 'SlidePod Clamp Cap'
    if bcap is not None:
        root.bRepBodies.add(bcap, base).name = 'SlidePod Brace Cap'
    for name, b in refs.items():
        rb = root.bRepBodies.add(b, base)
        rb.name = name
        rb.opacity = 0.35
    base.finishEdit()
    base.name = 'SlidePod mount (generated)'

    # --- soften outside edges --------------------------------------------
    hw_s = p['SNAP_W'] / 2 + p['SNAP_SLIT'] + 0.3

    def keep_sharp(x, y, z):      # mm; functional edges that must stay crisp
        in_pocket = px0 - 0.05 <= x <= px1 + 0.05 and py0 - 0.05 <= y <= py1 + 0.05             and z >= z_board - 0.05
        in_snap = y <= py0 + p['SNAP_GAP'] + 0.1 and             any(abs(x - c) <= hw_s for c in (-p['SNAP_X'], p['SNAP_X']))
        return in_pocket or in_snap

    if p['FILLET_R'] > 0:
        fillet_outside(design, root, 'SlidePod Mount', p['FILLET_R'], keep_sharp)
        if cap is not None:
            fillet_outside(design, root, 'SlidePod Clamp Cap', p['FILLET_R'], lambda *a: False)
        if bcap is not None:
            fillet_outside(design, root, 'SlidePod Brace Cap', p['FILLET_R'], lambda *a: False)
        mb = root.bRepBodies.itemByName('SlidePod Mount')

    bb = mb.boundingBox
    print('mount bbox mm: (%.1f, %.1f, %.1f) - (%.1f, %.1f, %.1f)' % (
        bb.minPoint.x * 10, bb.minPoint.y * 10, bb.minPoint.z * 10,
        bb.maxPoint.x * 10, bb.maxPoint.y * 10, bb.maxPoint.z * 10))
    if vee:
        print('V saddles: tube apex y=%.2f flat y=%.2f horn top y=%.2f; brace apex z=%.2f' % (
            tube_apex, tube_flat, horn_top, brace_apex))
    print('volume %.0f mm3, sensor face ~%.1f mm in front of brace' % (
        mb.volume * 1000, z_board + p['BOARD_T'] + 1.56))
