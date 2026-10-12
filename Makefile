SHELL := /usr/bin/env bash
export PATH := $(HOME)/.local/bin:$(PATH)

.PHONY: up check-tools cluster build deploy wait test status demo-reduction demo-anomaly demo-outage demo-latency link-down link-up logs down watch-raw watch-edge watch-cloud watch-link watch-all

up: check-tools cluster build deploy wait
	@echo "Grafana: http://localhost:3000"

check-tools:
	@scripts/check-tools.sh
cluster:
	@scripts/cluster-up.sh
build:
	@scripts/build-import.sh
deploy:
	@scripts/deploy.sh
wait:
	@scripts/wait-ready.sh
test:
	@demo/run-tests.sh
status:
	@scripts/status.sh
demo-reduction:
	@demo/01-data-reduction.sh
demo-anomaly:
	@demo/02-local-alert.sh
demo-outage:
	@demo/03-outage-backfill.sh
demo-latency:
	@demo/04-latency.sh
link-down:
	@demo/05-link-down.sh
link-up:
	@demo/06-link-up.sh
logs:
	@kubectl --context k3d-edge-cloud -n edge logs -l app=edge-aggregator --tail=50 2>/dev/null || kubectl --context k3d-edge-cloud -n edge logs deploy/edge-aggregator --tail=50
down:
	@scripts/cluster-down.sh
watch-raw:
	@watch/raw.sh
watch-edge:
	@watch/edge.sh
watch-cloud:
	@watch/cloud.sh
watch-link:
	@watch/link.sh
watch-all:
	@watch/all.sh
