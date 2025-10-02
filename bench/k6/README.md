# FleetLM k6 Benchmarks

WebSocket and HTTP load testing suite for FleetLM using [k6](https://k6.io/).

## Prerequisites

1. **Install k6**: https://k6.io/docs/get-started/installation/
   ```bash
   # macOS
   brew install k6

   # Linux
   sudo gpg -k
   sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
   echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
   sudo apt-get update
   sudo apt-get install k6
   ```

2. **FleetLM server running**: `mix phx.server` (default: http://localhost:4000)

3. **Echo agent running**: `mix run --no-halt bench/echo_agent.exs` (default: http://localhost:4001)

## Quick Start

```bash
# Terminal 1: Start FleetLM
cd /path/to/fleetlm
mix phx.server

# Terminal 2: Start echo agent
cd /path/to/fleetlm
mix run --no-halt bench/echo_agent.exs

# Terminal 3: Run benchmarks
cd /path/to/fleetlm
k6 run bench/k6/concurrent-sessions.js
```

## Available Benchmarks

### 1. Concurrent Sessions (`concurrent-sessions.js`)

Tests maximum concurrent WebSocket connections.

**What it measures:**
- Session creation latency under load
- WebSocket join latency
- Connection stability
- Memory usage per session

**Usage:**
```bash
# Default: 50 VUs for 2 minutes
k6 run bench/k6/concurrent-sessions.js

# Custom configuration
k6 run -e VUS=100 -e DURATION=5m bench/k6/concurrent-sessions.js

# Keep connections alive longer
k6 run -e KEEP_ALIVE_MS=120000 bench/k6/concurrent-sessions.js
```

**Key metrics:**
- `session_creation_ms` - Time to create session via API
- `ws_join_ms` - Time to join session channel
- `active_ws_connections` - Current active connections (gauge)
- `connection_failures` - Failed connections

### 2. Message Throughput (`message-throughput.js`)

Tests rapid message sending and processing capacity.

**What it measures:**
- Messages per second (aggregate and per session)
- Message append latency (client → server → broadcast)
- Agent webhook latency
- Backpressure behavior

**Usage:**
```bash
# Default: 10 VUs, 1 message/second for 1 minute
k6 run bench/k6/message-throughput.js

# High-frequency messages
k6 run -e VUS=20 -e SEND_INTERVAL=100 bench/k6/message-throughput.js

# Longer duration
k6 run -e DURATION=5m -e RUNTIME_MS=300000 bench/k6/message-throughput.js
```

**Key metrics:**
- `messages_sent` - Total messages sent
- `messages_received` - Total messages received (including echo)
- `append_latency_ms` - Round-trip time for messages
- `message_success_rate` - Percentage of successful messages
- `backpressure_events` - Times system pushed back

### 3. Session Lifecycle (`session-lifecycle.js`)

Tests realistic end-to-end user journeys.

**What it measures:**
- Complete lifecycle latency (create → message → disconnect)
- Session join time
- Message roundtrip time
- Cleanup success rate

**Usage:**
```bash
# Default: 10 VUs, 50 iterations each, 3 messages per session
k6 run bench/k6/session-lifecycle.js

# More sessions
k6 run -e VUS=20 -e ITERATIONS=100 bench/k6/session-lifecycle.js

# More messages per session
k6 run -e MESSAGES_PER_SESSION=10 bench/k6/session-lifecycle.js
```

**Key metrics:**
- `lifecycle_total_ms` - End-to-end time per session
- `join_latency_ms` - Time to join session
- `message_roundtrip_ms` - Message round-trip time
- `sessions_completed` - Successfully completed sessions
- `lifecycle_success_rate` - Percentage of successful lifecycles

### 4. Mixed Workload (`mixed-workload.js`)

Simulates realistic production load with multiple concurrent behaviors.

**What it measures:**
- Overall system performance under mixed load
- Resource contention effects
- Sustained throughput with varied patterns

**Scenarios:**
- **Long-lived sessions**: Occasional messages, connections stay open
- **Burst messages**: Rapid-fire messaging on fewer sessions
- **Session churn**: Continuous create → use → disconnect cycles

**Usage:**
```bash
# Light preset (default)
k6 run bench/k6/mixed-workload.js

# Standard preset
k6 run -e PRESET=standard bench/k6/mixed-workload.js

# Stress preset
k6 run -e PRESET=stress bench/k6/mixed-workload.js

# Custom VU counts
k6 run -e LONG_LIVED_VUS=50 -e BURST_VUS=25 -e CHURN_VUS=15 bench/k6/mixed-workload.js
```

**Presets:**

| Preset | Long-Lived | Burst | Churn | Duration |
|--------|------------|-------|-------|----------|
| light | 10 | 5 | 3 | 2m |
| standard | 30 | 15 | 10 | 5m |
| stress | 100 | 50 | 25 | 10m |

**Key metrics:**
- `messages_sent` / `messages_received` - Total throughput
- `append_latency_ms` - Overall message latency
- `active_connections` - Current connections (gauge)
- `session_churn_total` - Total sessions churned
- `message_success_rate` - Overall success percentage

### 5. WebSocket Hot Path (`ws_hot_path.js`)

Legacy benchmark for WebSocket message flow.

**Usage:**
```bash
k6 run bench/k6/ws_hot_path.js
```

## Environment Variables

All benchmarks support these common environment variables:

### Connection
- `API_URL` - FleetLM HTTP API base URL (default: `http://localhost:4000/api`)
- `WS_URL` - FleetLM WebSocket URL (default: `ws://localhost:4000/socket/websocket`)
- `AGENT_URL` - Echo agent URL (default: `http://localhost:4001`)
- `AGENT_ID` - Agent ID to use (default: `bench-echo-agent`)

### Test Parameters
- `VUS` - Number of virtual users (varies by benchmark)
- `DURATION` - Test duration (e.g., `1m`, `5m`, `10m`)
- `RUN_ID` - Unique identifier for this run (auto-generated if not provided)

### Debug
- `DEBUG=1` - Enable verbose logging

## Running Multiple Benchmarks

You can run benchmarks in parallel using separate terminals:

```bash
# Terminal 1: Concurrent sessions
k6 run -e RUN_ID=test1 bench/k6/concurrent-sessions.js

# Terminal 2: Message throughput (same time)
k6 run -e RUN_ID=test2 bench/k6/message-throughput.js
```

**Note**: Use different `RUN_ID` values to avoid participant/session ID collisions.

## Testing Against Remote Servers

```bash
# Staging
k6 run \
  -e API_URL=https://staging.example.com/api \
  -e WS_URL=wss://staging.example.com/socket/websocket \
  -e AGENT_URL=https://staging-echo.example.com \
  bench/k6/concurrent-sessions.js

# Production (careful!)
k6 run \
  -e API_URL=https://api.example.com/api \
  -e WS_URL=wss://api.example.com/socket/websocket \
  -e AGENT_URL=https://echo.example.com \
  -e VUS=10 \
  -e DURATION=1m \
  bench/k6/session-lifecycle.js
```

## Cloud Testing with k6 Cloud

```bash
# Sign up at https://k6.io/cloud/
# Login
k6 login cloud

# Run in k6 Cloud
k6 cloud bench/k6/concurrent-sessions.js

# Configure cloud run
k6 cloud -e VUS=500 -e DURATION=10m bench/k6/mixed-workload.js
```

## Interpreting Results

### Good Indicators
- `p(95)` latencies within threshold
- Success rates > 95%
- Stable connection counts
- Low backpressure events

### Warning Signs
- Increasing latency over time
- High failure rates
- Frequent backpressure
- Connection drops

### Example Output
```
✓ session_creation_ms........: avg=245ms  p(95)=450ms
✓ ws_join_ms.................: avg=120ms  p(95)=280ms
✓ append_latency_ms..........: avg=85ms   p(95)=180ms
✓ message_success_rate.......: 98.5%
  active_connections.........: 50 (current)
  messages_sent..............: 12450
  messages_received..........: 12350
```

## Echo Agent

The echo agent (`bench/echo_agent.exs`) is a minimal Elixir HTTP server that:
- Receives FleetLM webhook POSTs
- Immediately echoes back the last message
- Minimizes agent-side latency for pure FleetLM benchmarking

**Configuration:**
```bash
# Custom port
PORT=5000 mix run --no-halt bench/echo_agent.exs

# Check health
curl http://localhost:4001/health
```

## Troubleshooting

### "Failed to create agent"
Ensure the echo agent is running:
```bash
mix run --no-halt bench/echo_agent.exs
```

### "Connection refused"
Check that FleetLM is running:
```bash
mix phx.server
```

### High failure rates
- Reduce VUs or send interval
- Check server resources (CPU, memory, DB connections)
- Review FleetLM logs for errors

### Stale test data
Benchmarks create participants and sessions. Clean up manually if needed:
```bash
# List sessions with bench metadata
curl http://localhost:4000/api/sessions | jq '.sessions[] | select(.metadata.bench == true)'

# Delete a session
curl -X DELETE http://localhost:4000/api/sessions/{session_id}
```

## Best Practices

1. **Warm up**: Run a short test first to warm caches and connection pools
2. **Isolate**: Don't run benchmarks on production or with other heavy processes
3. **Monitor**: Watch server metrics (htop, database connections, etc.) during tests
4. **Iterate**: Start with light loads and gradually increase
5. **Document**: Record results, configurations, and system specs for comparison

## Contributing

When adding new benchmarks:
- Use `bench/k6/lib.js` for common utilities
- Follow existing naming conventions
- Document environment variables and metrics
- Test locally before committing
