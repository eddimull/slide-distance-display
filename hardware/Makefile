# SlidePod hardware pipeline. Everything runs in the kicad/kicad:9.0 container.
# Edit tools/circuit.py (parts + nets) or tools/gen_pcb.py (placement), then `make`.
K = tools/kicad.sh

all: check

slidepod.kicad_sch: tools/circuit.py tools/gen_sch.py tools/sexp.py
	$(K) python3 tools/gen_sch.py

slidepod.net: slidepod.kicad_sch
	$(K) kicad-cli sch export netlist -o slidepod.net slidepod.kicad_sch

# WARNING: regenerating the PCB discards any routing done in KiCad.
pcb: slidepod.net tools/gen_pcb.py
	rm -f slidepod.kicad_pcb
	$(K) python3 tools/gen_pcb.py

check: slidepod.net
	$(K) kicad-cli sch erc --severity-all -o erc.rpt slidepod.kicad_sch
	$(K) python3 tools/check_net.py
	$(K) kicad-cli pcb drc --severity-all --schematic-parity -o drc.rpt slidepod.kicad_pcb
	@grep -E "^\[" drc.rpt | sed 's/\].*/]/' | sort | uniq -c

pdf: slidepod.kicad_sch
	$(K) kicad-cli sch export pdf -o slidepod-schematic.pdf slidepod.kicad_sch

.PHONY: all pcb check pdf

# Fabrication outputs for JLCPCB (run after routing + a clean `make check`)
fab:
	mkdir -p fab/gerbers
	$(K) kicad-cli pcb export gerbers --board-plot-params -o fab/gerbers/ slidepod.kicad_pcb
	$(K) kicad-cli pcb export drill --format excellon --excellon-separate-th -o fab/gerbers/ slidepod.kicad_pcb
	$(K) kicad-cli pcb export pos --format csv --units mm --side front --exclude-dnp -o fab/slidepod-pos.csv slidepod.kicad_pcb
	$(K) python3 tools/export_jlc.py
	cd fab/gerbers && rm -f ../slidepod-gerbers.zip && zip -q ../slidepod-gerbers.zip *

# Freerouting round trip (needs java + .tools/freerouting.jar)
route:
	$(K) python3 tools/stitch.py fanout
	$(K) python3 tools/route.py export
	java -jar .tools/freerouting.jar --gui.enabled=false -de slidepod.dsn -do slidepod.ses -inc GND -mp 40
	$(K) python3 tools/route.py import
	$(K) python3 tools/finish_route.py
	$(K) python3 tools/stitch.py finish

.PHONY: fab route
