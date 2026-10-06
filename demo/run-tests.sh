#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"; repo_root
banner "Unit tests (edge-aggregator) in python:3.11-slim"
docker run --rm -v "$REPO_ROOT/edge-aggregator:/app" -w /app python:3.11-slim \
  bash -c "pip install -q -r requirements.txt -r requirements-dev.txt && pytest -q" \
  && pass "tests passed" || fail "tests failed"
