#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

echo -e "${GREEN}=== FleetLM Cluster Deployment ===${NC}"

# Check if terraform directory exists
if [ ! -d "$TERRAFORM_DIR" ]; then
  echo -e "${RED}Error: Terraform directory not found at $TERRAFORM_DIR${NC}"
  exit 1
fi

# Check if Terraform has been applied
if [ ! -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
  echo -e "${RED}Error: No terraform.tfstate found. Run 'terraform apply' first.${NC}"
  exit 1
fi

# Get outputs from Terraform
cd "$TERRAFORM_DIR"
echo -e "${YELLOW}Fetching Terraform outputs...${NC}"
INSTANCE_IPS=$(terraform output -json instance_ips | jq -r '.[]')
DATABASE_URL=$(terraform output -raw database_url)
CLUSTER_NODES=$(terraform output -raw cluster_nodes)
RDS_ADDRESS=$(terraform output -raw rds_address)

if [ -z "$INSTANCE_IPS" ]; then
  echo -e "${RED}Error: No instance IPs found. Check your Terraform configuration.${NC}"
  exit 1
fi

# Count instances
INSTANCE_COUNT=$(echo "$INSTANCE_IPS" | wc -l | tr -d ' ')
echo -e "${GREEN}Found $INSTANCE_COUNT instance(s)${NC}"

# Generate a secret key base
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

echo -e "${YELLOW}Waiting for RDS to be ready...${NC}"
echo "Checking connection to: $RDS_ADDRESS"
MAX_RETRIES=30
RETRY_COUNT=0
while ! nc -z -w5 "$RDS_ADDRESS" 5432 2>/dev/null; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo -e "${RED}Error: RDS not reachable after $MAX_RETRIES attempts${NC}"
    exit 1
  fi
  echo "  Attempt $RETRY_COUNT/$MAX_RETRIES..."
  sleep 10
done
echo -e "${GREEN}RDS is ready!${NC}"

# Deploy to each instance
INDEX=0
for IP in $INSTANCE_IPS; do
  INDEX=$((INDEX + 1))
  NODE_NAME="fleetlm-bench-$INDEX"

  echo ""
  echo -e "${GREEN}=== Deploying to $NODE_NAME ($IP) ===${NC}"

  # Wait for instance to be ready
  echo "Waiting for SSH to be available..."
  MAX_RETRIES=30
  RETRY_COUNT=0
  while ! ssh $SSH_OPTS ec2-user@$IP "echo 'SSH ready'" 2>/dev/null; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
      echo -e "${RED}Error: SSH not available after $MAX_RETRIES attempts${NC}"
      exit 1
    fi
    echo "  Attempt $RETRY_COUNT/$MAX_RETRIES..."
    sleep 10
  done

  # Wait for Docker to be ready
  echo "Waiting for Docker to be ready..."
  MAX_RETRIES=20
  RETRY_COUNT=0
  while ! ssh $SSH_OPTS ec2-user@$IP "docker ps" 2>/dev/null; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
      echo -e "${RED}Error: Docker not ready after $MAX_RETRIES attempts${NC}"
      exit 1
    fi
    echo "  Attempt $RETRY_COUNT/$MAX_RETRIES..."
    sleep 5
  done

  # Stop any existing container
  echo "Stopping any existing FleetLM containers..."
  ssh $SSH_OPTS ec2-user@$IP "docker stop fleetlm 2>/dev/null || true"
  ssh $SSH_OPTS ec2-user@$IP "docker rm fleetlm 2>/dev/null || true"

  # Pull the image
  echo "Pulling FleetLM image..."
  ssh $SSH_OPTS ec2-user@$IP "docker pull ghcr.io/cpluss/fleetlm:latest"

  # Only run migrations on the first node
  MIGRATE_ON_BOOT="false"
  if [ $INDEX -eq 1 ]; then
    MIGRATE_ON_BOOT="true"
    echo -e "${YELLOW}This node will run database migrations${NC}"
  fi

  # Start the container
  echo "Starting FleetLM container..."
  # Get the private IP for this instance
  PRIVATE_IP=$(ssh $SSH_OPTS ec2-user@$IP "hostname -i" | tr -d '\n')

  # Check if instance store NVMe is available
  HAS_NVME=$(ssh $SSH_OPTS ec2-user@$IP "test -d /mnt/nvme && echo 'yes' || echo 'no'")

  if [ "$HAS_NVME" = "yes" ]; then
    echo "Instance store NVMe detected - using for WAL storage"
    VOLUME_MOUNT="-v /mnt/nvme:/wal"
    SLOT_LOG_DIR="/wal"
  else
    echo "No instance store - using container filesystem"
    VOLUME_MOUNT=""
    SLOT_LOG_DIR=""
  fi

  ssh $SSH_OPTS ec2-user@$IP "docker run -d \
    --name fleetlm \
    --restart unless-stopped \
    -p 4000:4000 \
    -p 4369:4369 \
    -p 9100-9155:9100-9155 \
    $VOLUME_MOUNT \
    -e SECRET_KEY_BASE='$SECRET_KEY_BASE' \
    -e DATABASE_URL='$DATABASE_URL' \
    -e PHX_HOST='$IP' \
    -e PORT=4000 \
    -e PHX_SERVER=true \
    -e MIGRATE_ON_BOOT='$MIGRATE_ON_BOOT' \
    -e CLUSTER_NODES='$CLUSTER_NODES' \
    -e SLOT_LOG_DIR='$SLOT_LOG_DIR' \
    -e MIX_ENV=prod \
    -e RELEASE_DISTRIBUTION=name \
    -e RELEASE_NODE='fleetlm@$PRIVATE_IP' \
    ghcr.io/cpluss/fleetlm:latest"

  echo -e "${GREEN}Container started on $NODE_NAME${NC}"

  # Give the container a moment to start
  sleep 5

  # Check container status
  echo "Checking container status..."
  if ssh $SSH_OPTS ec2-user@$IP "docker ps | grep fleetlm" > /dev/null; then
    echo -e "${GREEN}✓ Container is running${NC}"
  else
    echo -e "${RED}✗ Container failed to start${NC}"
    echo "Container logs:"
    ssh $SSH_OPTS ec2-user@$IP "docker logs fleetlm"
    exit 1
  fi
done

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo ""
echo -e "${YELLOW}Cluster configuration:${NC}"
echo "  Nodes: $INSTANCE_COUNT"
echo "  Cluster: $CLUSTER_NODES"
echo ""
echo -e "${YELLOW}Instance access:${NC}"
INDEX=0
for IP in $INSTANCE_IPS; do
  INDEX=$((INDEX + 1))
  echo "  Node $INDEX: ssh ec2-user@$IP"
  echo "    HTTP: http://$IP:4000"
done
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo "  View logs: ssh ec2-user@<IP> 'docker logs -f fleetlm'"
echo "  Verify cluster: ssh ec2-user@<IP> 'docker exec fleetlm bin/fleetlm rpc \"Node.list()\"'"
echo "  Restart node: ssh ec2-user@<IP> 'docker restart fleetlm'"
echo ""
