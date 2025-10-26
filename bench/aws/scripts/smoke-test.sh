#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

echo -e "${GREEN}=== Fastpaca Smoke Test ===${NC}"

cd "$TERRAFORM_DIR"
INSTANCE_IPS=$(terraform output -json instance_ips | jq -r '.[]')

if [ -z "$INSTANCE_IPS" ]; then
  echo -e "${RED}Error: No instance IPs found. Run terraform apply first.${NC}"
  exit 1
fi

FIRST_IP=$(echo "$INSTANCE_IPS" | head -n1)
API_BASE="http://$FIRST_IP:4000/v1"

echo "Target node: $FIRST_IP"
echo "API: $API_BASE"
echo ""

CONTEXT_ID="bench-smoke-$(date +%s)"

echo -e "${YELLOW}Step 1: Creating context (${CONTEXT_ID})...${NC}"
CREATE_RESPONSE=$(curl -s -o /tmp/context_create.json -w "%{http_code}" \
  -X PUT "$API_BASE/contexts/$CONTEXT_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "token_budget": 100000,
    "policy": {"strategy": "last_n", "config": {"limit": 50}},
    "metadata": {"bench": true, "scenario": "smoke"}
  }')

if [ "$CREATE_RESPONSE" -lt 200 ] || [ "$CREATE_RESPONSE" -ge 300 ]; then
  echo -e "${RED}✗ Context creation failed (status $CREATE_RESPONSE)${NC}"
  cat /tmp/context_create.json
  exit 1
fi

echo -e "${GREEN}✓ Context created${NC}"

echo -e "${YELLOW}Step 2: Appending message...${NC}"
APPEND_RESPONSE=$(curl -s -o /tmp/context_append.json -w "%{http_code}" \
  -X POST "$API_BASE/contexts/$CONTEXT_ID/messages" \
  -H "Content-Type: application/json" \
  -d '{
    "message": {
      "role": "user",
      "parts": [{"type": "text", "text": "Hello from Fastpaca smoke test"}],
      "metadata": {"source": "smoke-test"}
    },
    "idempotency_key": "smoke-1"
  }')

if [ "$APPEND_RESPONSE" -lt 200 ] || [ "$APPEND_RESPONSE" -ge 300 ]; then
  echo -e "${RED}✗ Append failed (status $APPEND_RESPONSE)${NC}"
  cat /tmp/context_append.json
  exit 1
fi

SEQ=$(jq -r '.seq // empty' /tmp/context_append.json)
VERSION=$(jq -r '.version // empty' /tmp/context_append.json)

echo -e "${GREEN}✓ Message appended (seq: ${SEQ:-unknown}, version: ${VERSION:-unknown})${NC}"

echo -e "${YELLOW}Step 3: Fetching LLM context...${NC}"
WINDOW_RESPONSE=$(curl -s -o /tmp/context_window.json -w "%{http_code}" \
  "$API_BASE/contexts/$CONTEXT_ID/context")

if [ "$WINDOW_RESPONSE" != "200" ]; then
  echo -e "${RED}✗ Context window fetch failed (status $WINDOW_RESPONSE)${NC}"
  cat /tmp/context_window.json
  exit 1
fi

WINDOW_MESSAGES=$(jq '.messages | length' /tmp/context_window.json)
NEEDS_COMPACTION=$(jq '.needs_compaction' /tmp/context_window.json)

echo -e "${GREEN}✓ Context window retrieved (${WINDOW_MESSAGES} messages, needs_compaction=${NEEDS_COMPACTION})${NC}"

echo -e "${YELLOW}Step 4: Fetching tail messages...${NC}"
MESSAGES_RESPONSE=$(curl -s -o /tmp/context_messages.json -w "%{http_code}" \
  "$API_BASE/contexts/$CONTEXT_ID/messages?from_seq=-10")

if [ "$MESSAGES_RESPONSE" != "200" ]; then
  echo -e "${RED}✗ Message tail fetch failed (status $MESSAGES_RESPONSE)${NC}"
  cat /tmp/context_messages.json
  exit 1
fi

TAIL_COUNT=$(jq '.messages | length' /tmp/context_messages.json)

echo -e "${GREEN}✓ Tail fetched (${TAIL_COUNT} messages)${NC}"

echo ""
echo -e "${GREEN}=== Smoke Test Complete ===${NC}"
echo "Context ID: $CONTEXT_ID"
echo "Sample payload:"
jq '{messages: .messages, used_tokens: .used_tokens, needs_compaction: .needs_compaction}' /tmp/context_window.json

rm -f /tmp/context_create.json /tmp/context_append.json /tmp/context_window.json /tmp/context_messages.json
