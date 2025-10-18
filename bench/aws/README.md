# FleetLM AWS Benchmark Infrastructure

Reproducible Terraform configuration for benchmarking FleetLM on AWS.

## ⚠️ WARNING

This will deploy real AWS infrastructure and **incur costs**. All resources are **intentionally insecure** (no authentication, wide-open security groups). Use only for ephemeral benchmarks and destroy immediately after.

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.0
- `jq` installed
- SSH key pair

## Running Benchmarks

**1. Deploy infrastructure:**

```bash
cd bench/aws/terraform
terraform init
terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"
```

**2. Deploy application:**

```bash
cd ../scripts
./deploy.sh
./register-agent.sh
./test-agent.sh  # Verify setup works
```

**3. Run benchmark from AWS (eliminates WAN latency):**

```bash
./run-k6-remote.sh
```

**4. Teardown (important - stops billing):**

```bash
cd ../terraform
terraform destroy
```

## Configuration

Scale to 3 nodes:
```bash
terraform apply -var="instance_count=3"
```

Change instance type:
```bash
terraform apply -var="instance_type=c5d.xlarge"
```

## Results

See [docs/benchmarks.md](../../docs/benchmarks.md) for published results and methodology.
