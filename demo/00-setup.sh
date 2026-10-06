#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "SETUP: bootstrap the edge/cloud demo (k3d + images + manifests)"
command -v docker >/dev/null || die "docker not installed"
docker info >/dev/null 2>&1 || die "docker daemon not reachable"
if ! command -v k3d >/dev/null; then
  info "installing k3d $K3D_VERSION to ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  curl -fsSL -o "$HOME/.local/bin/k3d" "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-linux-amd64"
  chmod +x "$HOME/.local/bin/k3d"
fi
command -v kubectl >/dev/null || die "kubectl not installed"
info "k3d: $(k3d version | head -1)"
if cluster_exists; then
  info "cluster $CLUSTER exists; skipping host port check"
else
  busy=0
  for p in 3000 9090 8000 8080 8474; do
    if python3 -c "import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: s.bind(('0.0.0.0',$p))
except OSError: sys.exit(1)"; then info "port $p free"; else warn "port $p is in use"; busy=1; fi
  done
  [ $busy -eq 0 ] || die "free the busy ports above and retry"
fi
make up
echo
echo "${C_BOLD}Grafana: $GRAFANA (anonymous / admin:admin)${C_0}"
pass "stack is up"
