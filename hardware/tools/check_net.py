import sys
sys.path.insert(0, "/work/tools")
from sexp import parse, find, find_all
import circuit
net = parse(open("/work/slidepod.net").read())
got = {}
for n in find_all(find(net, "nets"), "net"):
    name = find(n, "name")[1].lstrip("/")
    for node in find_all(n, "node"):
        got[(find(node, "ref")[1], find(node, "pin")[1])] = name
bad = 0
for p in circuit.PARTS:
    for pin, nm in p.pins.items():
        g = got.get((p.ref, pin))
        if g != nm:
            bad += 1; print(f"MISMATCH {p.ref}.{pin}: want {nm} got {g}")
nets = {}
for (r, pin), nm in got.items():
    nets.setdefault(nm, []).append(f"{r}.{pin}")
single = [n for n, v in nets.items() if len(v) < 2 and not n.startswith("unconnected")]
print(f"{len(got)} pins in netlist, {bad} mismatches, single-pin nets: {single}")
