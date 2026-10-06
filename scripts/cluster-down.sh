#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; repo_root
banner "Teardown"
k3d cluster delete "$CLUSTER" || true
docker rmi "$SIM_IMAGE" "$AGG_IMAGE" >/dev/null 2>&1 || true
info "done"
exit 0
