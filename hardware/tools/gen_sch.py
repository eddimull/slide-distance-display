"""Generate slidepod.kicad_sch from circuit.py.

Every connected pin gets a short wire stub and a net label, so no wires are drawn
between parts. Unconnected pins get no-connect flags. UUIDs are deterministic, so
regenerating keeps the schematic-to-PCB links stable.
"""
import math
import sys
import uuid

sys.path.insert(0, "/work/tools")
from sexp import Sym, dump, find, find_all, parse  # noqa: E402
import circuit  # noqa: E402

LIB = "/usr/share/kicad/symbols"
NS = uuid.UUID("6b1d6a52-6f0c-4f4e-9d1a-5e1c0d7a51de")
ROOT = str(uuid.uuid5(NS, "root"))
G = 2.54


def uid(*key):
    return str(uuid.uuid5(NS, "/".join(map(str, key))))


def snap(v):
    return round(v / G) * G


_libs = {}


def lib_symbol(lib_id):
    """Return a flattened lib symbol named 'Lib:Name' plus its pin list."""
    lib, name = lib_id.split(":")
    if lib not in _libs:
        _libs[lib] = {s[1]: s for s in find_all(parse(open(f"{LIB}/{lib}.kicad_sym").read()), "symbol")}
    syms = _libs[lib]
    s = syms[name]
    ext = find(s, "extends")
    if ext:
        base = syms[ext[1]]
        props = {p[1]: p for p in find_all(s, "property")}
        body = []
        for e in base[2:]:
            if isinstance(e, list) and e[0] == "property" and e[1] in props:
                body.append(props.pop(e[1]))
            elif isinstance(e, list) and e[0] == "symbol":
                body.append([Sym("symbol"), e[1].replace(ext[1], name, 1)] + e[2:])
            else:
                body.append(e)
        body += list(props.values())
    else:
        body = [e for e in s[2:]]
    flat = [Sym("symbol"), lib_id] + body
    pins, xs, ys = [], [], []
    for u in find_all(flat, "symbol"):
        for p in find_all(u, "pin"):
            at = find(p, "at")
            pins.append({"num": find(p, "number")[1], "x": float(at[1]), "y": float(at[2]),
                         "ang": float(at[3]) if len(at) > 3 else 0.0})
            xs.append(float(at[1])); ys.append(float(at[2]))
        for r in find_all(u, "rectangle"):
            for k in ("start", "end"):
                pt = find(r, k); xs.append(float(pt[1])); ys.append(float(pt[2]))
    bbox = (min(xs, default=-2), max(xs, default=2), min(ys, default=-2), max(ys, default=2))
    return flat, pins, bbox


def font(size=1.27, hide=False, justify=None):
    e = [Sym("effects"), [Sym("font"), [Sym("size"), size, size]]]
    if justify:
        e.append([Sym("justify")] + [Sym(j) for j in justify.split()])
    if hide:
        e.append([Sym("hide"), Sym("yes")])
    return e


def prop(name, value, x, y, hide=False, justify=None, ang=0):
    return [Sym("property"), name, value, [Sym("at"), x, y, ang], font(hide=hide, justify=justify)]


def main():
    out_items, lib_defs = [], {}
    labels, wires, ncs = [], [], []

    def place(ref, lib_id, value, footprint, pinmap, x, y, extra_props=(), dnp=False, in_bom=True,
              on_board=True):
        flat, pins, (x0, x1, y0, y1) = lib_symbol(lib_id)
        lib_defs[lib_id] = flat
        su = uid("sym", ref)
        props = [prop("Reference", ref, x, snap(y - y1) - 1.27, justify="left" if False else None),
                 prop("Value", value, x, y - y0 + 2.54),
                 prop("Footprint", footprint, x, y, hide=True),
                 prop("Datasheet", "", x, y, hide=True)]
        props += [prop(k, v, x, y, hide=True) for k, v in extra_props]
        sym = [Sym("symbol"), [Sym("lib_id"), lib_id], [Sym("at"), x, y, 0], [Sym("unit"), 1],
               [Sym("exclude_from_sim"), Sym("no")], [Sym("in_bom"), Sym("yes" if in_bom else "no")],
               [Sym("on_board"), Sym("yes" if on_board else "no")], [Sym("dnp"), Sym("yes" if dnp else "no")],
               [Sym("uuid"), su]] + props
        seen = {}
        for p in pins:
            sym.append([Sym("pin"), p["num"], [Sym("uuid"), uid("pin", ref, p["num"])]])
            px, py = round(x + p["x"], 2), round(y - p["y"], 2)
            net = pinmap.get(p["num"])
            key = (px, py)
            if key in seen:
                if seen[key] != net:
                    raise SystemExit(f"{ref}: stacked pins at {key} on different nets {seen[key]} / {net}")
                continue
            seen[key] = net
            if net is None:
                ncs.append((px, py))
                continue
            out = math.radians(p["ang"] + 180)
            dx, dy = round(math.cos(out)), -round(math.sin(out))
            ex, ey = round(px + dx * G, 2), round(py + dy * G, 2)
            wires.append((px, py, ex, ey))
            ang = {(1, 0): 0, (-1, 0): 180, (0, -1): 90, (0, 1): 270}[(dx, dy)]
            labels.append((net, ex, ey, ang))
        missing = set(pinmap) - {p["num"] for p in pins}
        if missing:
            raise SystemExit(f"{ref}: pin(s) {sorted(missing)} not in symbol {lib_id}")
        sym.append([Sym("instances"), [Sym("project"), "slidepod",
                    [Sym("path"), f"/{ROOT}", [Sym("reference"), ref], [Sym("unit"), 1]]]])
        out_items.append(sym)
        return x1 - x0, y1 - y0

    # Layout: one row band per block, parts left to right, wrapping.
    texts = []
    y = 30.0
    order = ["power", "mcu", "tof", "piezo", "test"]
    for block in order:
        parts = [p for p in circuit.PARTS if p.block == block]
        texts.append((circuit.BLOCK_TITLES[block], 20, y - 12))
        x, row_h = 30.0, 0.0
        for p in parts:
            _, _, (x0, x1, y0, y1) = lib_symbol(p.lib_id)
            w, h = x1 - x0, y1 - y0
            if x + w > 560:
                x, y = 30.0, y + row_h + 25
                row_h = 0
            extra = [("LCSC", p.lcsc)] if p.lcsc else []
            if p.note:
                extra.append(("Note", p.note))
            place(p.ref, p.lib_id, p.value, p.footprint, p.pins, snap(x - x0), snap(y + y1), extra,
                  dnp=p.dnp, in_bom=not (p.ref.startswith("TP") or p.ref == "J3"))
            x += w + 30
            row_h = max(row_h, h)
        y += row_h + 45

    # Power flags
    x = 30.0
    for i, net in enumerate(circuit.PWR_FLAGS, 1):
        place(f"#FLG0{i}", "power:PWR_FLAG", "PWR_FLAG", "", {"1": net}, snap(x), snap(y),
              in_bom=False, on_board=False)
        x += 25
    texts.append(("Power flags", 20, y - 10))

    sch = [Sym("kicad_sch"), [Sym("version"), 20250114], [Sym("generator"), "eeschema"],
           [Sym("generator_version"), "9.0"], [Sym("uuid"), ROOT], [Sym("paper"), "A2"],
           [Sym("title_block"), [Sym("title"), "SlidePod: trombone slide sensor"],
            [Sym("rev"), "0.1"], [Sym("comment"), 1, "Generated by tools/gen_sch.py from tools/circuit.py; edit circuit.py, not this file"]],
           [Sym("lib_symbols")] + list(lib_defs.values())]
    for t, tx, ty in texts:
        sch.append([Sym("text"), t, [Sym("exclude_from_sim"), Sym("no")], [Sym("at"), tx, ty, 0],
                    font(size=3, justify="left"), [Sym("uuid"), uid("text", t)]])
    for i, (ax, ay, bx, by) in enumerate(wires):
        sch.append([Sym("wire"), [Sym("pts"), [Sym("xy"), ax, ay], [Sym("xy"), bx, by]],
                    [Sym("stroke"), [Sym("width"), 0], [Sym("type"), Sym("default")]],
                    [Sym("uuid"), uid("wire", ax, ay, bx, by)]])
    for net, lx, ly, ang in labels:
        # Global labels: net names carry no sheet prefix, so they match the PCB.
        just = "left" if ang in (0, 90) else "right"
        sch.append([Sym("global_label"), net, [Sym("shape"), Sym("passive")], [Sym("at"), lx, ly, ang],
                    [Sym("fields_autoplaced"), Sym("yes")], font(justify=just),
                    [Sym("uuid"), uid("label", net, lx, ly)],
                    [Sym("property"), "Intersheetrefs", "${INTERSHEET_REFS}", [Sym("at"), lx, ly, 0],
                     font(hide=True)]])
    for nx, ny in ncs:
        sch.append([Sym("no_connect"), [Sym("at"), nx, ny], [Sym("uuid"), uid("nc", nx, ny)]])
    sch += out_items
    sch.append([Sym("sheet_instances"), [Sym("path"), "/", [Sym("page"), "1"]]])
    sch.append([Sym("embedded_fonts"), Sym("no")])

    with open("/work/slidepod.kicad_sch", "w") as f:
        f.write(dump(sch) + "\n")
    print(f"wrote slidepod.kicad_sch: {len(out_items)} symbols, {len(labels)} labels, {len(ncs)} no-connects")


if __name__ == "__main__":
    main()
