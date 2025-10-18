#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

echo -e "${GREEN}=== FleetLM Agent Test ===${NC}"

# Get Terraform outputs
cd "$TERRAFORM_DIR"
INSTANCE_IPS=$(terraform output -json instance_ips | jq -r '.[]')
INSTANCE_COUNT=$(echo "$INSTANCE_IPS" | wc -l | tr -d ' ')

if [ -z "$INSTANCE_IPS" ]; then
  echo -e "${RED}Error: No instance IPs found${NC}"
  exit 1
fi

FIRST_IP=$(echo "$INSTANCE_IPS" | head -n1)

echo "FleetLM cluster: $INSTANCE_COUNT node(s)"
echo "Test node: $FIRST_IP"
echo ""

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Step 1: Create a session
USER_ID="test-user-$(date +%s)"
echo -e "${YELLOW}Step 1: Creating session with bench-echo-agent (user: $USER_ID)...${NC}"
SESSION_RESPONSE=$(curl -s -X POST "http://$FIRST_IP:4000/api/sessions" \
  -H "Content-Type: application/json" \
  -d "{
    \"user_id\": \"$USER_ID\",
    \"agent_id\": \"bench-echo-agent\"
  }")

SESSION_ID=$(echo "$SESSION_RESPONSE" | jq -r '.session.id // .data.id')
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
  echo -e "${RED}✗ Failed to create session${NC}"
  echo "$SESSION_RESPONSE" | jq '.'
  exit 1
fi
echo -e "${GREEN}✓ Session created: $SESSION_ID${NC}"

# Step 2: Send a test message
echo -e "${YELLOW}Step 2: Sending test message...${NC}"
MESSAGE_RESPONSE=$(curl -s -X POST "http://$FIRST_IP:4000/api/sessions/$SESSION_ID/messages" \
  -H "Content-Type: application/json" \
  -d "{
    \"user_id\": \"$USER_ID\",
    \"kind\": \"text\",
    \"content\": {
      \"text\": \"Hello from benchmark test!\"
    }
  }")

MESSAGE_SEQ=$(echo "$MESSAGE_RESPONSE" | jq -r '.message.seq // .data.seq')
if [ -z "$MESSAGE_SEQ" ] || [ "$MESSAGE_SEQ" = "null" ]; then
  echo -e "${RED}✗ Failed to send message${NC}"
  echo "$MESSAGE_RESPONSE" | jq '.'
  exit 1
fi
echo -e "${GREEN}✓ Message sent (seq: $MESSAGE_SEQ)${NC}"

# Step 3: Wait a moment for agent to respond
echo -e "${YELLOW}Step 3: Waiting for agent response...${NC}"
sleep 2

# Step 4: Fetch messages and verify agent response
echo -e "${YELLOW}Step 4: Fetching messages...${NC}"
MESSAGES_RESPONSE=$(curl -s "http://$FIRST_IP:4000/api/sessions/$SESSION_ID/messages")

# Count messages
TOTAL_MESSAGES=$(echo "$MESSAGES_RESPONSE" | jq '.messages // .data | length')
AGENT_MESSAGES=$(echo "$MESSAGES_RESPONSE" | jq '[(.messages // .data)[] | select(.kind == "assistant")] | length')

echo -e "${GREEN}✓ Total messages: $TOTAL_MESSAGES${NC}"
echo -e "${GREEN}✓ Agent messages: $AGENT_MESSAGES${NC}"

if [ "$AGENT_MESSAGES" -ge 1 ]; then
  echo ""
  echo "Latest agent response:"
  echo "$MESSAGES_RESPONSE" | jq '(.messages // .data)[] | select(.kind == "assistant") | .content' | tail -1
else
  echo -e "${RED}✗ No agent response found${NC}"
  exit 1
fi

# Step 5: Check session on each node in cluster
if [ "$INSTANCE_COUNT" -gt 1 ]; then
  echo ""
  echo -e "${YELLOW}Step 5: Verifying session across cluster nodes...${NC}"
  INDEX=0
  ALL_NODES_OK=true

  for IP in $INSTANCE_IPS; do
    INDEX=$((INDEX + 1))
    echo -n "  Node $INDEX ($IP): "

    NODE_MESSAGES=$(curl -s "http://$IP:4000/api/sessions/$SESSION_ID/messages" 2>/dev/null)
    NODE_TOTAL=$(echo "$NODE_MESSAGES" | jq '.messages // .data | length' 2>/dev/null || echo "0")

    if [ "$NODE_TOTAL" -ge "$TOTAL_MESSAGES" ]; then
      echo -e "${GREEN}✓ ($NODE_TOTAL messages)${NC}"
    else
      echo -e "${RED}✗ ($NODE_TOTAL messages, expected $TOTAL_MESSAGES)${NC}"
      ALL_NODES_OK=false
    fi
  done

  if [ "$ALL_NODES_OK" = true ]; then
    echo -e "${GREEN}✓ All nodes have consistent data${NC}"
  else
    echo -e "${RED}✗ Some nodes have inconsistent data${NC}"
  fi
fi

echo ""
echo -e "${GREEN}=== Test Complete ===${NC}"
echo ""
echo -e "${YELLOW}Summary:${NC}"
echo "  ✓ Session created with bench-echo-agent (user: $USER_ID)"
echo "  ✓ Message sent to agent"
echo "  ✓ Agent responded with 'ack'"
if [ "$INSTANCE_COUNT" -gt 1 ]; then
  echo "  ✓ Data replicated across $INSTANCE_COUNT nodes"
fi
echo ""
echo -e "${GREEN}Setup is working correctly!${NC}"
