#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; repo_root
banner "Deploy"
kc apply -k k8s/cloud
kc apply -f k8s/edge
