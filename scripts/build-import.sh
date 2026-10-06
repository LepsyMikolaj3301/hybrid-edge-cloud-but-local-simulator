#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; repo_root
banner "Build images"
docker build -t "$SIM_IMAGE" sensor-sim
docker build -t "$AGG_IMAGE" edge-aggregator
banner "Import images into k3d"
k3d image import "$SIM_IMAGE" "$AGG_IMAGE" -c "$CLUSTER"
