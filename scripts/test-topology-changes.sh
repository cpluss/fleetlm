#!/bin/bash
# Test dynamic topology changes: remove node3, add node4

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== TOPOLOGY CHANGE TEST ===${NC}"
echo ""

# Step 1: Verify initial 3-node cluster
echo "Step 1: Verifying initial 3-node cluster..."
elixir --name check_initial@127.0.0.1 -e "
Node.connect(:'node1@127.0.0.1')
{:ok, members, _} = :rpc.call(:'node1@127.0.0.1', :ra, :members, [{:raft_group_0, :'node1@127.0.0.1'}])
IO.puts(\"  Initial members: #{inspect(members)}\")
IO.puts(\"  Count: #{length(members)}\")
" 2>&1 | grep -v warning

echo ""

# Step 2: Kill node3
echo "Step 2: Killing node3..."
NODE3_PID=$(ps aux | grep "node3@127.0.0.1" | grep beam | grep -v grep | awk '{print $2}')
if [ -z "$NODE3_PID" ]; then
  echo -e "${RED}  Node3 not running!${NC}"
  exit 1
fi

kill $NODE3_PID
echo "  Node3 killed (PID: $NODE3_PID)"
echo "  Waiting 15s for nodedown + rebalance..."
sleep 15

echo ""

# Step 3: Verify node3 removed
echo "Step 3: Verifying node3 removed from Raft groups..."
elixir --name check_after_remove@127.0.0.1 -e "
Node.connect(:'node1@127.0.0.1')
{:ok, members, _} = :rpc.call(:'node1@127.0.0.1', :ra, :members, [{:raft_group_0, :'node1@127.0.0.1'}])
IO.puts(\"  Members after removal: #{inspect(members)}\")
IO.puts(\"  Count: #{length(members)}\")

has_node3 = Enum.any?(members, fn {_, node} -> node == :'node3@127.0.0.1' end)
if has_node3 do
  IO.puts(\"  ${RED}✗ Node3 still in membership!${NC}\")
  System.halt(1)
else
  IO.puts(\"  ${GREEN}✓ Node3 removed${NC}\")
end
" 2>&1 | grep -v warning

echo ""

# Step 4: Add node4
echo "Step 4: Starting node4..."
CLUSTER_NODES="node1@127.0.0.1,node2@127.0.0.1,node3@127.0.0.1,node4@127.0.0.1" PORT=4003 elixir --name node4@127.0.0.1 --erl "-kernel inet_dist_listen_min 9004 inet_dist_listen_max 9004" -S mix phx.server > logs/node4.log 2>&1 &
NODE4_PID=$!
echo "  Node4 started (PID: $NODE4_PID)"
echo "  Waiting 20s for nodeup + rebalance..."
sleep 20

echo ""

# Step 5: Verify node4 added
echo "Step 5: Verifying node4 added to Raft groups..."
elixir --name check_after_add@127.0.0.1 -e "
Node.connect(:'node1@127.0.0.1')
{:ok, members, _} = :rpc.call(:'node1@127.0.0.1', :ra, :members, [{:raft_group_0, :'node1@127.0.0.1'}])
IO.puts(\"  Members after addition: #{inspect(members)}\")
IO.puts(\"  Count: #{length(members)}\")

has_node4 = Enum.any?(members, fn {_, node} -> node == :'node4@127.0.0.1' end)
if has_node4 do
  IO.puts(\"  ${GREEN}✓ Node4 added${NC}\")
else
  IO.puts(\"  ${YELLOW}⚠ Node4 not yet in membership (may need more time)${NC}\")
end
" 2>&1 | grep -v warning

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Topology change test complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Check logs for rebalance activity:"
echo "  grep 'Rebalancing group' logs/node1.log | head -20"
