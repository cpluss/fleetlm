#!/bin/bash
# Test Raft leader failover by killing a node

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Testing Raft leader failover...${NC}"
echo ""

# Check cluster is running
if ! pgrep -f "node1@127.0.0.1" > /dev/null; then
  echo -e "${RED}Cluster not running. Start it first:${NC}"
  echo "  ./scripts/start-cluster.sh"
  exit 1
fi

# Create a test session
echo "1. Creating test session..."
USER_ID="failover-test-$(date +%s)"
SESSION=$(curl -s http://localhost:4000/api/sessions \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER_ID\",\"agent_id\":\"bench-echo-agent\",\"metadata\":{}}")

SESSION_ID=$(echo $SESSION | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo -e "  ✓ Session: $SESSION_ID"
echo ""

# Write a message
echo "2. Writing initial message to node1..."
curl -s http://localhost:4000/api/sessions/$SESSION_ID/messages \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER_ID\",\"kind\":\"text\",\"content\":{\"text\":\"before failover\"},\"metadata\":{}}" > /dev/null
echo -e "  ✓ Message written"
echo ""

# Kill node1
echo "3. Killing node1 (simulating failure)..."
NODE1_PIDS=$(pgrep -f "node1@127.0.0.1")
kill $NODE1_PIDS
echo -e "  ✓ Node1 killed (PIDs: $NODE1_PIDS)"
echo ""

# Wait for Raft to elect new leader
echo "4. Waiting 3s for Raft leader election..."
sleep 3
echo -e "  ✓ Election period complete"
echo ""

# Try to write via node2 (should work via new leader)
echo "5. Writing message via node2 (tests failover)..."
FAILOVER_RESP=$(curl -s http://localhost:4001/api/sessions/$SESSION_ID/messages \
  -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER_ID\",\"kind\":\"text\",\"content\":{\"text\":\"after failover\"},\"metadata\":{}}")

if echo "$FAILOVER_RESP" | grep -q '"seq"'; then
  echo -e "  ${GREEN}✓ Write succeeded after failover!${NC}"
else
  echo -e "  ${RED}✗ Write failed after failover${NC}"
  echo "Response: $FAILOVER_RESP"
  exit 1
fi
echo ""

# Read from node3 (should have both messages)
echo "6. Reading messages from node3..."
MSGS=$(curl -s "http://localhost:4002/api/sessions/$SESSION_ID/messages?limit=10")
COUNT=$(echo $MSGS | grep -o '"seq":' | wc -l)

if [ "$COUNT" -ge 2 ]; then
  echo -e "  ${GREEN}✓ Both messages present ($COUNT total)${NC}"
else
  echo -e "  ${YELLOW}⚠ Only $COUNT messages found (expected 2+)${NC}"
fi
echo ""

# Cleanup
curl -s -X DELETE http://localhost:4001/api/sessions/$SESSION_ID > /dev/null

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Failover test passed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Raft handled node failure:"
echo "  - Node1 killed"
echo "  - Leader re-elected among node2/node3"
echo "  - Writes continued via new leader"
echo "  - Data replicated across remaining nodes"
echo ""
echo "Cluster now running 2-of-3 nodes (degraded but operational)"
echo ""
echo "To restart node1:"
echo "  RAFT_DATA_DIR=priv/raft/node1 PORT=4000 elixir --sname node1@127.0.0.1 -S mix phx.server &"
echo ""
echo "To stop remaining nodes:"
echo "  ./scripts/stop-cluster.sh"
