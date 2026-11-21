#!/bin/sh
# Run a command inside a KiCad 10 container with hardware/ mounted at /work.
# The image is the official kicad/kicad:10.0 plus numpy (tools/Dockerfile), built on first use.
# A persistent HOME (.kicad-home, gitignored) holds the default library tables.
HW="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=slidepod-kicad:10.0
mkdir -p "$HW/.kicad-home"
docker image inspect $IMAGE >/dev/null 2>&1 || (cd "$HW/tools" && docker build -q -t $IMAGE . >&2)
exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/work/.kicad-home -v "$HW":/work -w /work $IMAGE \
  sh -c 'C=$HOME/.config/kicad/10.0; if [ ! -f $C/sym-lib-table ]; then mkdir -p $C;
         cp /usr/share/kicad/template/sym-lib-table /usr/share/kicad/template/fp-lib-table $C/; fi; exec "$@"' -- "$@"
