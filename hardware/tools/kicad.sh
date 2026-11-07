#!/bin/sh
# Run a command inside the official KiCad 9 container with hardware/ mounted at /work.
# A persistent HOME (.kicad-home, gitignored) holds the default library tables.
HW="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HW/.kicad-home"
exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/work/.kicad-home -v "$HW":/work -w /work kicad/kicad:9.0 \
  sh -c 'C=$HOME/.config/kicad/9.0; if [ ! -f $C/sym-lib-table ]; then mkdir -p $C;
         cp /usr/share/kicad/template/sym-lib-table /usr/share/kicad/template/fp-lib-table $C/; fi; exec "$@"' -- "$@"
