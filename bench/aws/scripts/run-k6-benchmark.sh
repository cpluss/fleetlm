#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
K6_DIR="$SCRIPT_DIR/../../k6"

echo -e "${GREEN}=== FleetLM k6 Benchmark ===${NC}"

# Check if k6 is installed
if ! command -v k6 &> /dev/null; then
  echo -e "${RED}Error: k6 is not installed${NC}"
  echo "Install it from: https://k6.io/docs/get-started/installation/"
  exit 1
fi

# Get Terraform outputs
cd "$TERRAFORM_DIR"
INSTANCE_IPS=$(terraform output -json instance_ips | jq -r '.[]')

if [ -z "$INSTANCE_IPS" ]; then
  echo -e "${RED}Error: No instance IPs found. Run terraform apply first.${NC}"
  exit 1
fi

FIRST_IP=$(echo "$INSTANCE_IPS" | head -n1)

# Build URLs
API_URL="http://$FIRST_IP:4000/api"
WS_URL="ws://$FIRST_IP:4000/socket/websocket"

echo "Target instance: $FIRST_IP"
echo "API URL: $API_URL"
echo "WS URL: $WS_URL"
echo ""

# Default benchmark parameters
BENCHMARK="${1:-message-throughput}"
MAX_VUS="${MAX_VUS:-10}"
PIPELINE_DEPTH="${PIPELINE_DEPTH:-5}"
RAMP_DURATION="${RAMP_DURATION:-30s}"
STEADY_DURATION="${STEADY_DURATION:-1m}"
RAMP_DOWN_DURATION="${RAMP_DOWN_DURATION:-10s}"

echo -e "${YELLOW}Benchmark configuration:${NC}"
echo "  Script: $BENCHMARK.js"
echo "  Max VUs: $MAX_VUS"
echo "  Pipeline depth: $PIPELINE_DEPTH"
echo "  Ramp: $RAMP_DURATION → Steady: $STEADY_DURATION → Down: $RAMP_DOWN_DURATION"
echo ""

# Check if benchmark script exists
BENCHMARK_SCRIPT="$K6_DIR/$BENCHMARK.js"
if [ ! -f "$BENCHMARK_SCRIPT" ]; then
  echo -e "${RED}Error: Benchmark script not found: $BENCHMARK_SCRIPT${NC}"
  echo "Available benchmarks:"
  ls -1 "$K6_DIR"/*.js 2>/dev/null || echo "  (none found)"
  exit 1
fi

echo -e "${YELLOW}Starting k6 benchmark...${NC}"
echo ""

# Run k6 with environment variables
cd "$K6_DIR"
k6 run \
  -e API_URL="$API_URL" \
  -e WS_URL="$WS_URL" \
  -e AGENT_ID="bench-echo-agent" \
  -e MAX_VUS="$MAX_VUS" \
  -e PIPELINE_DEPTH="$PIPELINE_DEPTH" \
  -e RAMP_DURATION="$RAMP_DURATION" \
  -e STEADY_DURATION="$STEADY_DURATION" \
  -e RAMP_DOWN_DURATION="$RAMP_DOWN_DURATION" \
  "$BENCHMARK.js"

echo ""
echo -e "${GREEN}=== Benchmark Complete ===${NC}"
