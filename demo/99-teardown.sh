#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "TEARDOWN"
make down
pass "cluster removed"
