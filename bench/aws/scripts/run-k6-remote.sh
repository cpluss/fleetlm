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

echo -e "${GREEN}=== FleetLM Remote k6 Benchmark (from AWS) ===${NC}"

# Get Terraform outputs
cd "$TERRAFORM_DIR"
BENCHMARK_CLIENT_IP=$(terraform output -raw benchmark_client_ip)
FLEETLM_PRIVATE_IP=$(terraform output -json instance_private_ips | jq -r '.[0]')

if [ -z "$BENCHMARK_CLIENT_IP" ]; then
  echo -e "${RED}Error: No benchmark client IP found${NC}"
  exit 1
fi

if [ -z "$FLEETLM_PRIVATE_IP" ]; then
  echo -e "${RED}Error: No FleetLM instance IP found${NC}"
  exit 1
fi

echo "Benchmark client: $BENCHMARK_CLIENT_IP"
echo "FleetLM target: $FLEETLM_PRIVATE_IP (private IP, same VPC)"
echo ""

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Wait for benchmark client to be ready
echo -e "${YELLOW}Waiting for benchmark client SSH...${NC}"
MAX_RETRIES=30
RETRY_COUNT=0
while ! ssh $SSH_OPTS ec2-user@$BENCHMARK_CLIENT_IP "echo 'ready'" 2>/dev/null; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo -e "${RED}Error: SSH not available${NC}"
    exit 1
  fi
  echo "  Attempt $RETRY_COUNT/$MAX_RETRIES..."
  sleep 10
done
echo -e "${GREEN}SSH ready${NC}"

# Verify k6 is installed
echo -e "${YELLOW}Verifying k6 installation...${NC}"
if ! ssh $SSH_OPTS ec2-user@$BENCHMARK_CLIENT_IP "k6 version" > /dev/null 2>&1; then
  echo -e "${RED}Error: k6 not installed on benchmark client${NC}"
  echo "Wait for user_data to complete or SSH in and install manually"
  exit 1
fi
echo -e "${GREEN}k6 is installed${NC}"

# Copy k6 scripts to benchmark client
echo -e "${YELLOW}Copying k6 scripts to benchmark client...${NC}"
ssh $SSH_OPTS ec2-user@$BENCHMARK_CLIENT_IP "rm -rf ~/k6"
scp $SSH_OPTS -r "$K6_DIR" ec2-user@$BENCHMARK_CLIENT_IP:~/
echo -e "${GREEN}Scripts copied${NC}"

# Benchmark configuration
BENCHMARK="${1:-message-throughput}"
MAX_VUS="${MAX_VUS:-10}"
PIPELINE_DEPTH="${PIPELINE_DEPTH:-5}"
RAMP_DURATION="${RAMP_DURATION:-30s}"
STEADY_DURATION="${STEADY_DURATION:-1m}"
RAMP_DOWN_DURATION="${RAMP_DOWN_DURATION:-10s}"

# Build URLs (using private IP for same-VPC communication)
API_URL="http://$FLEETLM_PRIVATE_IP:4000/api"
WS_URL="ws://$FLEETLM_PRIVATE_IP:4000/socket/websocket"

echo ""
echo -e "${YELLOW}Benchmark configuration:${NC}"
echo "  Script: $BENCHMARK.js"
echo "  Max VUs: $MAX_VUS"
echo "  Pipeline depth: $PIPELINE_DEPTH"
echo "  API URL: $API_URL (private VPC)"
echo "  WS URL: $WS_URL (private VPC)"
echo ""

echo -e "${YELLOW}Running k6 benchmark on remote instance...${NC}"
echo ""

# Run k6 remotely
ssh $SSH_OPTS ec2-user@$BENCHMARK_CLIENT_IP "cd ~/k6 && \
  API_URL='$API_URL' \
  WS_URL='$WS_URL' \
  AGENT_ID='bench-echo-agent' \
  MAX_VUS='$MAX_VUS' \
  PIPELINE_DEPTH='$PIPELINE_DEPTH' \
  RAMP_DURATION='$RAMP_DURATION' \
  STEADY_DURATION='$STEADY_DURATION' \
  RAMP_DOWN_DURATION='$RAMP_DOWN_DURATION' \
  k6 run $BENCHMARK.js"

echo ""
echo -e "${GREEN}=== Remote Benchmark Complete ===${NC}"
echo ""
echo -e "${YELLOW}Note: Test ran from AWS VPC (eliminates WAN latency)${NC}"
echo "This represents realistic performance for AWS-hosted API clients."
