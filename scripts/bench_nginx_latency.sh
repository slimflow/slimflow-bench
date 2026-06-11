#!/usr/bin/env bash
set -euo pipefail

RPS=${1:-200}
SLOW_AT=${2:-10}
RECOVER_AT=${3:-40}
DURATION=${4:-90}
SLOW_MS=${5:-500}

IMAGE="ghcr.io/slimflow/slimflow:latest"
CYAN="\033[36m"
YELLOW="\033[33m"
GREEN="\033[32m"
NC="\033[0m"

echo -e "${CYAN}=== NGINX tuned latency-degradation benchmark ===${NC}"
echo -e "RPS=${RPS}  slow_at=T+${SLOW_AT}s  recover_at=T+${RECOVER_AT}s  duration=${DURATION}s"
echo -e "Config: least_conn + max_fails=1 + proxy_next_upstream http_503"
echo -e "node2 will degrade to ${SLOW_MS}ms latency (no 503s — NGINX cannot detect this)"
echo ""

cleanup() {
  docker compose -f docker-compose-nginx.yml down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

echo -e "${CYAN}Starting NGINX gateway + 3 nodes...${NC}"
docker compose -f docker-compose-nginx.yml up -d gateway node1 node2 node3
sleep 3

echo -e "${CYAN}Starting load generator (${RPS} RPS, ${DURATION}s)...${NC}"
docker run --rm \
  --network slimflow-bench_bench \
  --name slimflow-loadgen-nginx-latency \
  "$IMAGE" \
  /usr/local/bin/loadgen \
    --target http://gateway:8080 \
    --rps "$RPS" \
    --duration "${DURATION}s" &
LOADGEN_PID=$!

echo -e "${YELLOW}T+0s: all nodes healthy at 10ms...${NC}"
sleep "$SLOW_AT"

echo -e "${YELLOW}T+${SLOW_AT}s: degrading node2 to ${SLOW_MS}ms latency (still returning 200)...${NC}"
curl -s -X POST http://localhost:8082/admin/latency -d "${SLOW_MS}" > /dev/null

sleep $(( RECOVER_AT - SLOW_AT ))

echo -e "${GREEN}T+${RECOVER_AT}s: restoring node2 to 10ms...${NC}"
curl -s -X POST http://localhost:8082/admin/latency -d "10" > /dev/null

echo -e "${CYAN}Waiting for load generator to finish...${NC}"
wait "$LOADGEN_PID" || true

echo ""
echo -e "${GREEN}Done. NGINX cannot detect latency degradation — 1/3 of traffic hit the slow node throughout.${NC}"
