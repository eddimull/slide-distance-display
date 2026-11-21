"""Cross-check the rev 0.2 firmware pin map against the routed PCB.

Reads U1's (ESP32-S3-MINI-1) pad nets from hardware/slidepod.kicad_pcb, converts module
pin numbers to GPIOs, and checks every PIN_* constant in the SLIDEPOD_REV >= 2 block of
src/slidepod/main.cpp lands on the net it is named for. Exit 1 on any mismatch.
"""
import re, sys, pathlib
root = pathlib.Path(__file__).resolve().parents[2]  # repo root (hardware/tools/ -> ../..)
pcb = (root / "hardware/slidepod.kicad_pcb").read_text(encoding="utf-8")
src = (root / "src/slidepod/main.cpp").read_text(encoding="utf-8")

# ESP32-S3-MINI-1 module pin -> GPIO (datasheet pin table)
MOD = {4: 0, 5: 1, 6: 2, 7: 3, 8: 4, 9: 5, 10: 6, 11: 7, 12: 8, 13: 9, 14: 10, 15: 11, 16: 12,
       17: 13, 18: 14, 19: 15, 20: 16, 21: 17, 22: 18, 23: 19, 24: 20, 25: 21, 26: 26, 27: 47,
       28: 33, 29: 34, 30: 48, 31: 35, 32: 36, 33: 37, 34: 38, 35: 39, 36: 40, 37: 41, 38: 42,
       39: 43, 40: 44, 41: 45, 42: 46}

# U1 footprint block -> pad number -> net name
i = pcb.find('(property "Reference" "U1"')
if i < 0: sys.exit("U1 not found in PCB")
j = pcb.find("\n\t(footprint", i)
u1 = pcb[i:j if j > 0 else len(pcb)]
gpio_net = {}
# each pad block: (pad "N" ... (net "NAME") ... ) -- split on pad starts so nets never leak across pads
for blk in re.split(r'\n\t\t\(pad ', u1)[1:]:
    m = re.match(r'"(\d+)"', blk); n = re.search(r'\(net (?:\d+ )?"([^"]+)"\)', blk)
    if m and n and int(m.group(1)) in MOD: gpio_net[MOD[int(m.group(1))]] = n.group(1)

blk = re.search(r"#if SLIDEPOD_REV >= 2(.*?)#else", src, re.S).group(1)
consts = dict((k, int(v)) for k, v in re.findall(r"constexpr int (PIN_\w+)\s*=\s*(\d+)", blk))
consts["PIN_BOOT"] = int(re.search(r"PIN_BOOT\s*=\s*(\d+);\n\s*// PIEZO", src).group(1))
want = {"PIN_LED_R": "LED_R", "PIN_LED_G": "LED_G", "PIN_LED_B": "LED_B", "PIN_SCL": "TOF_SCL",
        "PIN_SDA": "TOF_SDA", "PIN_TOF_INT": "TOF_INT", "PIN_TOF_XSHUT": "TOF_XSHUT",
        "PIN_IMU_SCL": "IMU_SCL", "PIN_IMU_SDA": "IMU_SDA", "PIN_IMU_INT": "IMU_INT", "PIN_BOOT": "BOOT"}
bad = 0
for k, g in sorted(consts.items()):
    got = gpio_net.get(g, "<unconnected>")
    ok = got == want.get(k)
    bad += not ok
    print(f"{'OK  ' if ok else 'FAIL'} {k:14} GPIO{g:<3} -> PCB net {got:12} (want {want.get(k)})")
used = {n for n in gpio_net.values()}
print("other U1 signal nets:", ", ".join(sorted(f"IO{g}={n}" for g, n in gpio_net.items()
      if n not in want.values() and not n.startswith("unconnected"))))
sys.exit(1 if bad else 0)
