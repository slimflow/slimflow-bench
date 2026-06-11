#!/usr/bin/env bash
set -euo pipefail

RPS=${1:-200}
FAIL_AT=${2:-10}
RECOVER_AT=${3:-40}
DURATION=${4:-90}

IMAGE="ghcr.io/slimflow/slimflow:latest"
CYAN="\033[36m"
YELLOW="\033[33m"
GREEN="\033[32m"
NC="\033[0m"

echo -e "${CYAN}=== NGINX tuned benchmark ===${NC}"
echo -e "RPS=${RPS}  fail_at=T+${FAIL_AT}s  recover_at=T+${RECOVER_AT}s  duration=${DURATION}s"
echo -e "Config: least_conn + max_fails=1 + proxy_next_upstream http_503"
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
  --name slimflow-loadgen-nginx \
  "$IMAGE" \
  /usr/local/bin/loadgen \
    --target http://gateway:8080 \
    --rps "$RPS" \
    --duration "${DURATION}s" &
LOADGEN_PID=$!

echo -e "${YELLOW}T+0s: all nodes healthy...${NC}"
sleep "$FAIL_AT"

echo -e "${YELLOW}T+${FAIL_AT}s: saturating node2 (capacity → 1)...${NC}"
curl -s -X POST http://localhost:8082/admin/capacity -d "1" > /dev/null

sleep $(( RECOVER_AT - FAIL_AT ))

echo -e "${GREEN}T+${RECOVER_AT}s: restoring node2 (capacity → 50)...${NC}"
curl -s -X POST http://localhost:8082/admin/capacity -d "50" > /dev/null

echo -e "${CYAN}Waiting for load generator to finish...${NC}"
wait "$LOADGEN_PID" || true

echo ""
echo -e "${GREEN}Done. Compare results with ./scripts/bench.sh (Slimflow).${NC}"
