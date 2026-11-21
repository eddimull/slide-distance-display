# KiCad 10 plus the Python packages the routing tools need (finish_route.py uses numpy).
# tools/kicad.sh builds this as slidepod-kicad:10.0 on first use.
FROM kicad/kicad:10.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3-numpy && rm -rf /var/lib/apt/lists/*
USER kicad
