"""Minimal S-expression reader/writer for KiCad files."""
import re

_TOKEN = re.compile(r'\s*(?:(\()|(\))|("(?:[^"\\]|\\.)*")|([^\s()"]+))')


class Sym(str):
    """Bare (unquoted) atom."""


def parse(text):
    stack, cur = [], []
    pos = 0
    n = len(text)
    while pos < n:
        m = _TOKEN.match(text, pos)
        if not m:
            if text[pos:].strip() == "":
                break
            raise ValueError(f"bad token at {pos}: {text[pos:pos+40]!r}")
        pos = m.end()
        lp, rp, s, atom = m.groups()
        if lp:
            stack.append(cur)
            cur = []
        elif rp:
            done = cur
            cur = stack.pop()
            cur.append(done)
        elif s is not None:
            cur.append(bytes(s[1:-1], "utf-8").decode("unicode_escape"))
        elif atom is not None:
            cur.append(Sym(atom))
    return cur[0] if len(cur) == 1 else cur


def dump(x, indent=0):
    if isinstance(x, list):
        if not x:
            return "()"
        simple = all(not isinstance(e, list) for e in x)
        if simple:
            return "(" + " ".join(dump(e) for e in x) + ")"
        pad = "\t" * (indent + 1)
        parts = [dump(x[0], indent)]
        for e in x[1:]:
            parts.append("\n" + pad + dump(e, indent + 1) if isinstance(e, list) else dump(e))
        return "(" + " ".join(parts[:1]) + "".join(
            p if p.startswith("\n") else " " + p for p in parts[1:]) + ")"
    if isinstance(x, Sym):
        return str(x)
    if isinstance(x, bool):
        return "yes" if x else "no"
    if isinstance(x, (int, float)):
        return f"{x:.4f}".rstrip("0").rstrip(".") if isinstance(x, float) else str(x)
    s = str(x).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{s}"'


def find(node, key):
    for e in node:
        if isinstance(e, list) and e and e[0] == key:
            return e
    return None


def find_all(node, key):
    return [e for e in node if isinstance(e, list) and e and e[0] == key]
