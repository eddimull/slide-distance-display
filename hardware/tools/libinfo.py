import sys
sys.path.insert(0, "/work/tools")
from sexp import parse, find, find_all
LIB = "/usr/share/kicad/symbols"
cache = {}
def load(lib):
    if lib not in cache:
        cache[lib] = parse(open(f"{LIB}/{lib}.kicad_sym").read())
    return cache[lib]
def sym(lib, name):
    for s in find_all(load(lib), "symbol"):
        if s[1] == name:
            return s
for arg in sys.argv[1:]:
    lib, name = arg.split(":")
    s = sym(lib, name)
    ext = find(s, "extends")
    props = {p[1]: p[2] for p in find_all(s, "property")}
    print(f"== {arg} extends={ext[1] if ext else None} FP={props.get('Footprint')}")
    base = sym(lib, ext[1]) if ext else s
    pins = []
    for u in find_all(base, "symbol"):
        for p in find_all(u, "pin"):
            num = find(p, "number")[1]; nm = find(p, "name")[1]
            pins.append(f"{num}:{nm}:{p[1]}")
    print("  ", " ".join(pins))
