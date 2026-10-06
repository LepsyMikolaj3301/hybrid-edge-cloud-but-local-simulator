#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; repo_root
banner "Cluster $CLUSTER"
if cluster_exists; then
  info "cluster $CLUSTER already exists, skipping create"
  k3d cluster start "$CLUSTER" >/dev/null 2>&1 || true
else
  k3d cluster create "$CLUSTER" --servers 1 --agents 0 \
    --k3s-arg "--disable=traefik@server:0" \
    -p "3000:30300@server:0" -p "9090:30090@server:0" -p "8000:30800@server:0" \
    -p "8080:30080@server:0" -p "8474:30474@server:0" --wait
fi
kc get nodes
