# FleetLM AWS Benchmark Infrastructure

This directory contains Terraform configuration and deployment scripts for running FleetLM benchmark clusters on AWS.

**⚠️ WARNING**: This infrastructure is **INTENTIONALLY INSECURE** for ephemeral benchmarking only. DO NOT use in production.

## Overview

- **RDS Postgres**: Publicly accessible database (db.t3.small - 2GB RAM)
- **EC2 FleetLM nodes**: Configurable number of c5d.large instances (2 vCPU, 50GB NVMe)
- **EC2 Benchmark client**: t3.micro for running k6 in same VPC (eliminates WAN latency)
- **API Gateway Echo Agent**: Static mock integration returning AI SDK JSONL (free tier, no Lambda/backend)
- **Security**: Wide open (0.0.0.0/0) - no authentication required
- **Clustering**: Erlang distributed via libcluster (EPMD strategy)

## Prerequisites

1. AWS CLI configured with credentials:
   ```bash
   aws configure
   ```

2. Terraform installed (>= 1.0)

3. SSH key pair (either existing in AWS or provide your public key)

4. `jq` installed (for deployment scripts):
   ```bash
   # macOS
   brew install jq

   # Linux
   apt-get install jq  # or yum install jq
   ```

5. `k6` installed (for benchmarks):
   ```bash
   # macOS
   brew install k6

   # Linux/Windows
   # See https://k6.io/docs/get-started/installation/
   ```

## Quick Start

### 1. Deploy Infrastructure (Single Node)

```bash
cd bench/aws/terraform

# Initialize Terraform
terraform init

# Create infrastructure (1 node by default)
terraform apply

# Or with your SSH public key
terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"
```

This creates:
- 1 RDS Postgres instance (takes ~5 minutes)
- 1 EC2 t3.medium instance
- Security groups for clustering
- Outputs: instance IPs, RDS endpoint, cluster configuration

### 2. Deploy Application

```bash
cd ../scripts

# Deploy FleetLM containers to all nodes
./deploy.sh
```

This will:
- Wait for RDS to be ready
- Wait for EC2 instances to have Docker installed
- Pull `ghcr.io/cpluss/fleetlm:latest`
- Start containers with proper clustering config
- Run migrations on first node only

### 3. Verify Cluster

```bash
./verify-cluster.sh
```

This checks:
- Container status on each node
- HTTP endpoint responsiveness
- Erlang cluster connectivity

### 4. Get Echo Agent URL

```bash
cd ../terraform
terraform output echo_agent_url
# Example: https://abc123.execute-api.us-east-1.amazonaws.com/webhook

# Test it
terraform output echo_agent_url | xargs curl -X POST
# Should return AI SDK JSONL:
# {"type":"text-start","id":"part_1"}
# {"type":"text-delta","id":"part_1","delta":"ack"}
# {"type":"text-end","id":"part_1"}
# {"type":"finish"}
```

### 5. Register Echo Agent

```bash
./register-agent.sh
```

This registers the API Gateway echo agent with FleetLM.

### 6. Test the Setup

```bash
./test-agent.sh
```

This will:
- Create a test user
- Create a session with the echo agent
- Send a test message
- Verify the agent responds with "ack"
- Check data consistency across all cluster nodes (if multi-node)

If this passes, your setup is working correctly!

### 7. Run k6 Benchmarks

**Recommended: Run from AWS benchmark client (same VPC, ~0.5ms latency)**

```bash
cd scripts

# Default: 10 VUs, pipeline depth 5
./run-k6-remote.sh

# Find maximum capacity
MAX_VUS=50 ./run-k6-remote.sh message-throughput-unlimited

# Custom parameters
MAX_VUS=100 PIPELINE_DEPTH=20 ./run-k6-remote.sh
```

This runs k6 from the dedicated benchmark client instance in the same AWS VPC, eliminating WAN latency while still being "remote" from the server.

**Alternative: Run from local machine (30-50ms latency)**

```bash
./run-k6-benchmark.sh
```

Note: Local runs will be limited by network RTT (~300-400 msg/s). Use remote runs for accurate capacity testing.

**Available benchmarks:**
- `message-throughput` (default) - Sustainable throughput with flow control
- `message-throughput-unlimited` - Find breaking point (fails on first error)
- `message-correctness` - Verify message ordering

**Environment variables:**
- `MAX_VUS` - Maximum virtual users (default: 10)
- `PIPELINE_DEPTH` - Max in-flight messages per VU (default: 5)
- `RAMP_DURATION` - Ramp up time (default: 30s)
- `STEADY_DURATION` - Steady state duration (default: 1m)
- `RAMP_DOWN_DURATION` - Ramp down time (default: 10s)

### 8. Scale to 3 Nodes

```bash
cd ../terraform

# Scale up
terraform apply -var="instance_count=3"

# Redeploy to configure clustering
cd ../scripts
./deploy.sh

# Verify 3-node cluster
./verify-cluster.sh
```

### 9. Teardown

```bash
cd ../terraform
terraform destroy
```

## Configuration

All configuration is in `terraform/variables.tf`:

```hcl
variable "instance_count" {
  default = 1  # Change to 3 for cluster benchmarks
}

variable "instance_type" {
  default = "t3.medium"  # Or "t3.large", "c5.2xlarge", etc.
}

variable "region" {
  default = "us-east-1"  # Or your preferred region
}
```

Override at apply time:

```bash
terraform apply \
  -var="instance_count=3" \
  -var="instance_type=t3.large" \
  -var="region=us-west-2"
```

## Accessing Nodes

Get connection info:

```bash
cd terraform

# List all IPs
terraform output instance_ips

# SSH commands
terraform output ssh_commands

# Database URL
terraform output database_url
```

Access nodes:

```bash
# SSH
ssh ec2-user@<IP>

# View logs
ssh ec2-user@<IP> 'docker logs -f fleetlm'

# Interactive shell
ssh ec2-user@<IP> 'docker exec -it fleetlm /bin/sh'

# Run Elixir code
ssh ec2-user@<IP> 'docker exec fleetlm bin/fleetlm eval "Node.list()"'

# HTTP access
curl http://<IP>:4000
```

## Troubleshooting

### Container won't start

```bash
ssh ec2-user@<IP> 'docker logs fleetlm'
```

Common issues:
- RDS not reachable (check security groups)
- Invalid environment variables
- Port conflicts

### Cluster not forming

Check EPMD and node names:

```bash
ssh ec2-user@<IP> 'docker exec fleetlm bin/fleetlm eval "Node.list()"'
ssh ec2-user@<IP> 'docker exec fleetlm bin/fleetlm eval "Node.self()"'
```

Check CLUSTER_NODES env var:

```bash
ssh ec2-user@<IP> 'docker exec fleetlm env | grep CLUSTER'
```

### RDS connection issues

Test from EC2 instance:

```bash
ssh ec2-user@<IP> 'nc -zv <RDS_ADDRESS> 5432'
```

### Redeploy single node

```bash
# Stop and remove container
ssh ec2-user@<IP> 'docker stop fleetlm && docker rm fleetlm'

# Re-run deploy script (will restart that node)
cd scripts
./deploy.sh
```

## Cost Estimation

Approximate hourly costs (eu-west-2):
- RDS db.t3.small: ~$0.034/hour
- EC2 c5d.large (FleetLM): ~$0.096/hour per instance
- EC2 t3.micro (benchmark client): ~$0.0104/hour
- API Gateway: **FREE** (1M requests/month free tier)
- Data transfer: negligible for benchmarks

**Single node + client**: ~$0.14/hour (~$3.36/day)
**3-node cluster + client**: ~$0.33/hour (~$7.92/day)

Remember to destroy when done!

## Security Notes

This setup is **COMPLETELY INSECURE** by design:
- All ports open to 0.0.0.0/0
- Database publicly accessible
- Default passwords
- No TLS/SSL
- No authentication

**ONLY USE FOR EPHEMERAL BENCHMARKS**. Destroy immediately after testing.

## Files

```
bench/aws/
├── terraform/
│   ├── main.tf                # EC2 FleetLM instances + provider config
│   ├── rds.tf                 # RDS Postgres (SSL disabled, t3.small)
│   ├── benchmark_client.tf    # EC2 t3.micro for k6 (same VPC)
│   ├── api_gateway_rest.tf    # API Gateway mock integration for echo agent
│   ├── security_groups.tf     # Wide-open security groups
│   ├── variables.tf           # Configuration variables
│   ├── outputs.tf             # IPs, endpoints, connection info
│   └── .gitignore            # Ignore terraform state
├── scripts/
│   ├── deploy.sh             # Deploy containers to all nodes
│   ├── verify-cluster.sh     # Verify cluster health
│   ├── register-agent.sh     # Register echo agent with FleetLM
│   ├── test-agent.sh         # Test agent + verify setup
│   ├── run-k6-remote.sh      # Run k6 from AWS benchmark client (recommended)
│   └── run-k6-benchmark.sh   # Run k6 from local machine
└── README.md                 # This file
```
