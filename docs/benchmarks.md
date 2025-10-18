---
sidebar_position: 5
---

# Benchmarks

## Current Results

| Date | Commit | Setup | Throughput | CPU | Memory | Notes |
|------|--------|-------|------------|-----|--------|-------|
| 2025-10-17 | `650292e` | 1 node, c5d.large | ~800 msg/s | 40% | 130MB | Durable writes, NVMe WAL |

## Methodology

**What we measure:** Durable message throughput with real fsync guarantees. Every ack means the message is persisted.

### Infrastructure

- **FleetLM node**: AWS EC2 c5d.large (2 vCPU, 4GB RAM, 50GB NVMe instance store)
- **Database**: AWS RDS db.t3.small (Postgres 15, SSL disabled for benchmarks)
- **Mock agent**: API Gateway with static response (eliminates agent latency)
- **Optional: Test client**: k6 from separate EC2 instance in same AWS VPC (eliminates WAN latency)

All infrastructure defined in reproducible Terraform configuration.

### Durability Guarantees

FleetLM prioritizes **durability and predictability** over raw throughput:

- **Durable writes**: Every message ack guarantees fsync to NVMe storage
- **No data loss**: Messages survive process crashes and restarts
- **Bounded latency**: Timeouts prevent unbounded queueing
- **Batch persistence**: WAL flushes to Postgres every 300ms in background

This is a **durable conversation store with strong guarantees**, not an in-memory message queue.

### Test Configuration

- **Virtual users**: 30 concurrent k6 VUs
- **Pipeline depth**: 5 in-flight messages per VU
- **Duration**: 1 minute steady state after 30s ramp

## Interpretation

**~800 msg/s sustained throughput** on 2 vCPU means:
- Each message is durably written to NVMe before ack
- 40% CPU usage = not CPU-bound, intentionally throttled for durability
- 130MB flat memory = no memory leaks or unbounded growth
- Zero data loss under normal operation

This represents the **sustainable capacity** with full durability guarantees, not burst capacity with buffering.

### Comparison to Other Systems

Most "high-throughput" message systems report numbers with:
- In-memory buffering (no persistance)
- Eventual durability (ack before persistence)
- Unbounded memory growth under load

FleetLM trades raw throughput for **predictable, durable behavior** suitable for production conversation storage.

## How to Reproduce

See [bench/aws/README.md](../bench/aws/README.md) for full setup.

Quick start:
```bash
cd bench/aws/terraform
terraform init
terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"

cd ../scripts
./deploy.sh
./register-agent.sh
./run-k6-remote.sh
```

Test infrastructure tears down cleanly:
```bash
cd bench/aws/terraform
terraform destroy
```
