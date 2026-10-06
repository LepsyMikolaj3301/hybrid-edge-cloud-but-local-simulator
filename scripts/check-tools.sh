#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; repo_root
missing=0
for t in docker kubectl k3d curl python3; do
  if command -v "$t" >/dev/null 2>&1; then info "found $t"; else warn "missing: $t (k3d: run demo/00-setup.sh)"; missing=1; fi
done
docker info >/dev/null 2>&1 || { warn "docker daemon not reachable"; missing=1; }
exit $missing
