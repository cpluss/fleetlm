#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

echo -e "${GREEN}=== FleetLM Echo Agent Registration ===${NC}"

# Get Terraform outputs
cd "$TERRAFORM_DIR"
ECHO_AGENT_URL=$(terraform output -raw echo_agent_url)
INSTANCE_IPS=$(terraform output -json instance_ips | jq -r '.[]')

if [ -z "$INSTANCE_IPS" ]; then
  echo -e "${RED}Error: No instance IPs found${NC}"
  exit 1
fi

FIRST_IP=$(echo "$INSTANCE_IPS" | head -n1)

echo "Echo Agent URL: $ECHO_AGENT_URL"
echo "Registering on FleetLM instance: $FIRST_IP"
echo ""

# Register the agent
echo -e "${YELLOW}Registering echo agent...${NC}"
# Extract base URL (remove /webhook from the end)
BASE_URL="${ECHO_AGENT_URL%/webhook}"

RESPONSE=$(curl -s -X POST "http://$FIRST_IP:4000/api/agents" \
  -H "Content-Type: application/json" \
  -d "{
    \"agent\": {
      \"id\": \"bench-echo-agent\",
      \"name\": \"Bench Echo Agent\",
      \"origin_url\": \"$BASE_URL\",
      \"webhook_path\": \"/webhook\",
      \"message_history_mode\": \"last\",
      \"message_history_limit\": 1,
      \"timeout_ms\": 5000
    }
  }")

# Check if registration succeeded
if echo "$RESPONSE" | jq -e '.agent.id' > /dev/null 2>&1; then
  echo -e "${GREEN}✓ Agent registered successfully${NC}"
  echo ""
  echo "Agent details:"
  echo "$RESPONSE" | jq '.agent'
else
  echo -e "${RED}✗ Agent registration failed${NC}"
  echo "Response:"
  echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
  exit 1
fi

echo ""
echo -e "${GREEN}=== Registration Complete ===${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Run ./test-agent.sh to verify the setup"
echo "  2. Start benchmarking!"
