# IronClaw High-Density Deployment

Run 1,000+ IronClaw agents on a single GCP VM using Nomad orchestration, Traefik load balancing, and shared PostgreSQL.

## Architecture

```
Internet
  │
  ├─ :80   → Traefik → IronClaw shards (webhook API)
  ├─ :9000 → Traefik → IronClaw shards (gateway UI)
  └─ :4646 → Nomad UI
              │
              ├─ ironclaw-shards (10x Docker containers)
              │    └─ shared Postgres (Cloud SQL)
              │    └─ LLM API (NEAR AI or mock)
              ├─ traefik (host networking)
              └─ mockllm (optional, for stress testing)
```

Each shard runs a single-threaded tokio runtime (`TOKIO_WORKER_THREADS=1`) with multi-tenant mode enabled. All user state is in PostgreSQL — any shard can serve any user.

## Prerequisites

- GCP project with billing enabled
- `gcloud` CLI authenticated
- Terraform installed

## Step 1: Provision Infrastructure

```bash
cd deploy/terraform

terraform init
terraform apply -var project_id=YOUR_PROJECT_ID -var nearai_api_key=YOUR_KEY
```

This creates:
- Cloud SQL PostgreSQL 15 instance (2 vCPU, 8 GB)
- Artifact Registry for Docker images
- GCE VM (e2-standard-4: 4 vCPU, 16 GB) with Docker and Nomad pre-installed
- Firewall rules for ports 22, 80, 4646, 8080, 8081, 9000

Note the outputs — you'll need `vm_public_ip`, `database_url`, and `ssh_command`.

## Step 2: Initialize the Database

```bash
# SSH into the VM
gcloud compute ssh ironclaw-nomad-node --zone us-central1-a

# Connect to Cloud SQL and enable pgvector
psql "$(terraform output -raw database_url)" -f deploy/setup.sql
```

## Step 3: Build the Docker Image

From the repo root on the VM:

```bash
cd ~/ironclaw
docker build -t ironclaw:local -f deploy/nomad/Dockerfile.slim .
```

This takes ~15 minutes on first build (Rust compilation). Subsequent builds use cached dependencies (~30 seconds).

Optionally push to Artifact Registry:

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
docker tag ironclaw:local us-central1-docker.pkg.dev/PROJECT/ironclaw-repo/ironclaw:latest
docker push us-central1-docker.pkg.dev/PROJECT/ironclaw-repo/ironclaw:latest
```

## Step 4: Configure Nomad

Start Nomad with config files (not dev mode):

```bash
sudo nomad agent -config /etc/nomad.d/ &
```

Minimal `/etc/nomad.d/nomad.hcl`:

```hcl
data_dir  = "/opt/nomad/data"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
  servers = ["127.0.0.1"]
}

plugin "docker" {
  config {
    auth {
      config = "/root/.docker/config.json"
    }
  }
}
```

## Step 5: Store Secrets

Secrets are stored in Nomad Variables — never in job specs or source control.

```bash
nomad var put nomad/jobs/ironclaw-shards \
  NEARAI_API_KEY=sk-agent-... \
  NEARAI_BASE_URL=https://private-chat-stg.near.ai \
  NEARAI_MODEL=Qwen/Qwen3-30B-A3B-Instruct-2507 \
  DATABASE_URL='postgres://ironclaw_app:PASSWORD@DB_IP:5432/ironclaw?sslmode=disable' \
  SECRETS_MASTER_KEY=$(openssl rand -hex 32) \
  GATEWAY_ADMIN_TOKEN=$(openssl rand -hex 24) \
  HTTP_WEBHOOK_SECRET=$(openssl rand -hex 16)
```

## Step 6: Deploy

```bash
cd deploy/nomad

# Deploy Traefik (load balancer)
nomad job run traefik.nomad.hcl

# Deploy IronClaw shards
nomad job run ironclaw.nomad.hcl
```

Verify:

```bash
# Health check through Traefik
curl http://VM_PUBLIC_IP/health
# → {"status":"healthy","channel":"http"}

# Nomad UI
open http://VM_PUBLIC_IP:4646
```

## Scaling

Change the `count` in `ironclaw.nomad.hcl` and re-run:

```bash
# Edit count = 20
nomad job run ironclaw.nomad.hcl
```

Nomad performs a rolling update — no downtime.

Resource budget per shard: 500 MHz CPU, 512 MB RAM. The default VM (e2-standard-4: 4 vCPU, 16 GB) fits ~10-20 shards comfortably.

## User Management

Create users via the admin API:

```bash
# Get the gateway token from the shard logs
nomad alloc logs ALLOC_ID | grep gateway

# Create a user
curl -s http://VM_IP:9000/api/admin/users \
  -H "Authorization: Bearer GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"display_name": "Alice", "role": "member"}'
# → Returns one-time token

# User accesses their agent at:
# http://VM_IP:9000/?token=THEIR_TOKEN
```

For bulk user creation, see `deploy/nomad/create-users.py`.

## Mock LLM (Stress Testing)

Uses [StacklokLabs/mockllm](https://github.com/StacklokLabs/mockllm) for unlimited-throughput testing without LLM rate limits.

```bash
# Build the mock image
cd deploy/nomad/mockllm
docker build -t mockllm:local .

# Deploy with mock LLM
./deploy.sh --mock

# Or manually:
nomad job run mockllm.nomad.hcl
nomad var put -force nomad/jobs/ironclaw-shards \
  NEARAI_API_KEY=mock-key \
  NEARAI_BASE_URL=http://localhost:4010 \
  NEARAI_MODEL=mock-model \
  ...other vars unchanged...

# Stop mock and switch back to real LLM
./deploy.sh --stop-mock
```

## Stress Testing

```bash
cd deploy/nomad

# Infrastructure test (async, no LLM wait)
python3 stress-infra.py http://VM_IP

# Full pipeline test (sync, with LLM response)
python3 stress-test.py http://VM_IP WEBHOOK_SECRET

# Send hello to all users in users.csv
python3 hello-all-users.py
```

## File Layout

```
deploy/
├── README.md                    # This file
├── setup.sql                    # Database initialization (pgvector)
├── terraform/                   # GCP infrastructure
│   ├── main.tf                  # Cloud SQL, Artifact Registry, GCE VM
│   ├── variables.tf             # Configurable parameters
│   └── outputs.tf               # Connection strings, IPs, commands
└── nomad/                       # Nomad orchestration
    ├── ironclaw.nomad.hcl       # Agent shards (main job)
    ├── ironclaw-worker.nomad.hcl # Batch worker (dispatched sessions)
    ├── traefik.nomad.hcl        # Load balancer
    ├── mockllm.nomad.hcl        # Mock LLM for testing
    ├── mockllm/                 # Mock LLM Docker image
    │   ├── Dockerfile
    │   └── responses.yml
    ├── Dockerfile.slim          # IronClaw production image
    ├── deploy.sh                # Deploy script (--mock flag)
    ├── create-users.py          # Bulk user creation
    ├── hello-all-users.py       # Send messages to all users
    ├── stress-test.py           # LLM stress test
    ├── stress-infra.py          # Infrastructure stress test
    └── test-scale.py            # Basic scale verification
```

## Known Limits

| Resource | Limit | Scope |
|----------|-------|-------|
| Webhook rate limit | 60 req/min | Per shard |
| NEAR AI staging API | 10 req/60s | Per API key |
| Gateway chat rate limit | 30 req/60s | Per user |
| Max SSE/WS connections | 100 | Per shard |

## Switching LLM Backend

Update Nomad Variables and redeploy:

```bash
# Switch to production NEAR AI
nomad var put -force nomad/jobs/ironclaw-shards \
  NEARAI_BASE_URL=https://private-chat-stg.near.ai \
  NEARAI_API_KEY=sk-agent-... \
  NEARAI_MODEL=Qwen/Qwen3-30B-A3B-Instruct-2507
nomad job stop ironclaw-shards && nomad job run ironclaw.nomad.hcl

# Switch to mock LLM
nomad var put -force nomad/jobs/ironclaw-shards \
  NEARAI_BASE_URL=http://localhost:4010 \
  NEARAI_API_KEY=mock-key \
  NEARAI_MODEL=mock-model
nomad job stop ironclaw-shards && nomad job run ironclaw.nomad.hcl
```
