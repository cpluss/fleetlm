#!/bin/bash
# Test that the 3-node cluster is working correctly

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Testing 3-node Raft cluster...${NC}"
echo ""

# Check all nodes are running
echo "1. Checking nodes are running..."
for port in 4000 4001 4002; do
  if curl -s http://localhost:$port/api/agents > /dev/null; then
    echo -e "  ✓ Node on port $port is up"
  else
    echo -e "${RED}  ✗ Node on port $port is down${NC}"
    exit 1
  fi
done
echo ""

# Create a session via node1
echo "2. Creating test session via node1..."
USER_ID="test-user-$(date +%s)"
AGENT_ID="bench-echo-agent"

SESSION=$(curl -s http://localhost:4000/api/sessions \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER_ID\",\"agent_id\":\"$AGENT_ID\",\"metadata\":{\"test\":true}}")

SESSION_ID=$(echo $SESSION | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$SESSION_ID" ]; then
  echo -e "${RED}  ✗ Failed to create session${NC}"
  exit 1
fi

echo -e "  ✓ Session created: $SESSION_ID"
echo ""

# Write a message via node1
echo "3. Writing message via node1..."
MSG_RESP=$(curl -s http://localhost:4000/api/sessions/$SESSION_ID/messages \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER_ID\",\"kind\":\"text\",\"content\":{\"text\":\"cluster test\"},\"metadata\":{}}")

MSG_SEQ=$(echo $MSG_RESP | grep -o '"seq":[0-9]*' | cut -d':' -f2)

if [ -z "$MSG_SEQ" ]; then
  echo -e "${RED}  ✗ Failed to write message${NC}"
  echo "Response: $MSG_RESP"
  exit 1
fi

echo -e "  ✓ Message written with seq: $MSG_SEQ"
echo ""

# Read from node2 (different node - tests Raft replication)
# No wait needed - ack means quorum write completed!
echo "4. Reading message from node2 (tests Raft replication)..."
MSGS=$(curl -s "http://localhost:4001/api/sessions/$SESSION_ID/messages?limit=10")
READ_COUNT=$(echo $MSGS | grep -o '"seq":' | wc -l)

if [ "$READ_COUNT" -lt 1 ]; then
  echo -e "${RED}  ✗ Message not replicated to node2${NC}"
  echo "Response: $MSGS"
  exit 1
fi

echo -e "  ✓ Message replicated to node2"
echo ""

# Read from node3 (third node)
echo "5. Reading message from node3 (tests full cluster replication)..."
MSGS=$(curl -s "http://localhost:4002/api/sessions/$SESSION_ID/messages?limit=10")
READ_COUNT=$(echo $MSGS | grep -o '"seq":' | wc -l)

if [ "$READ_COUNT" -lt 1 ]; then
  echo -e "${RED}  ✗ Message not replicated to node3${NC}"
  exit 1
fi

echo -e "  ✓ Message replicated to node3"
echo ""

# Cleanup
echo "6. Cleaning up test session..."
curl -s -X DELETE http://localhost:4000/api/sessions/$SESSION_ID > /dev/null
echo -e "  ✓ Session deleted"
echo ""

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ All cluster tests passed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Cluster is healthy:"
echo "  - All 3 nodes responding"
echo "  - Write to node1 works"
echo "  - Replication to node2 works"
echo "  - Replication to node3 works"
echo ""
echo "Ready for benchmarks:"
echo "  k6 run bench/k6/1-hot-path-throughput.js"
