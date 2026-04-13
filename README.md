# IronClaw High-Density Deployment

Run 1,000+ IronClaw agents on a single GCP VM using Nomad orchestration, Traefik load balancing, and shared PostgreSQL.

## Architecture

```
Internet
  │
  ├─ :443  → Traefik (HTTPS) → IronClaw shards (webhook API)
  ├─ :80   → Traefik → redirects to :443
  ├─ :9000 → Traefik (HTTPS) → IronClaw shards (gateway UI)
  ├─ :8646 → oauth2-proxy (Google SSO) → Nomad UI
  └─ :8081 → Traefik dashboard (SSH tunnel only)
              │
              ├─ ironclaw-shards (10x Docker containers)
              │    └─ shared Postgres (Cloud SQL)
              │    └─ LLM API (NEAR AI or mock)
              ├─ traefik (host networking, self-signed TLS)
              ├─ oauth2-proxy (Google SSO for Nomad UI)
              └─ mockllm (optional, for stress testing)
```

TLS uses a self-signed cert for `<VM_IP>.sslip.io` (browsers show warning). Replace with Let's Encrypt when a real domain is available.

Each shard runs a single-threaded tokio runtime (`TOKIO_WORKER_THREADS=1`) with multi-tenant mode enabled. All user state is in PostgreSQL — any shard can serve any user.

## Prerequisites

- GCP project with billing enabled
- `gcloud` CLI authenticated
- Terraform installed

## Step 1: Provision Infrastructure

```bash
cd terraform

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
psql "$(terraform output -raw database_url)" -f setup.sql
```

## Step 3: Build and Push the Docker Image

> **This repo is the deployment overlay only — it does not contain the IronClaw Rust source.** `nomad/Dockerfile.slim` and `nomad/Dockerfile.worker` must be built from the IronClaw monorepo root (which has `Cargo.toml`, `src/`, `crates/`, etc.). Copy or symlink this overlay's `nomad/` directory into the IronClaw source tree before building.

The shard image is pulled from Artifact Registry at deploy time, not built on the VM. Build and push from a dev machine (or CI):

```bash
# In the IronClaw monorepo, with this overlay's nomad/ directory present:
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

IMAGE=us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw
TAG=$(git rev-parse --short HEAD)

docker build -t "$IMAGE:$TAG" -t "$IMAGE:latest" -f nomad/Dockerfile.slim .
docker push "$IMAGE:$TAG"
docker push "$IMAGE:latest"
```

First build takes ~15 minutes (Rust compilation); subsequent builds use cached dependencies (~30 seconds).

The Nomad job (`nomad/ironclaw.nomad.hcl`) defaults to the `:latest` tag with `force_pull = true`. Pin to a specific SHA at deploy time:

```bash
nomad job run -var ironclaw_image="$IMAGE:$TAG" nomad/ironclaw.nomad.hcl
```

### Worker image (sandbox jobs)

The worker image is launched by the **IronClaw agent code itself** (not by Nomad) when it dispatches per-turn sandbox containers via the host Docker socket. The agent hardcodes the tag `ironclaw-worker:latest`, so the VM's local Docker daemon must have an image under that exact tag — Artifact Registry alone isn't enough.

Build, push, then pull-and-retag on the VM:

```bash
WORKER=us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw-worker

docker build -t "$WORKER:$TAG" -t "$WORKER:latest" -f nomad/Dockerfile.worker .
docker push "$WORKER:$TAG"
docker push "$WORKER:latest"

gcloud compute ssh ironclaw-nomad-node --zone us-central1-a -- "
  docker pull $WORKER:latest &&
  docker tag $WORKER:latest ironclaw-worker:latest
"
```

Properly decoupling the worker tag from the literal `ironclaw-worker:latest` (so Nomad / a config var can pick the image) requires changes in the IronClaw agent's job-dispatch code — out of scope for this overlay.

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

  host_volume "docker-sock" {
    path      = "/var/run/docker.sock"
    read_only = false
  }
}

plugin "docker" {
  config {
    auth {
      config = "/root/.docker/config.json"
    }
    allow_privileged = true
    volumes {
      enabled = true
    }
  }
}
```

**Important:** The `plugin "docker"` block must be in the main `nomad.hcl`, not a separate file. Nomad may not apply Docker plugin config from separate HCL files.

The Terraform startup script (`terraform/main.tf`) writes this exact config and starts Nomad as a systemd service, so a fresh `terraform apply` produces a node ready to run jobs without manual Nomad configuration.

Configure Docker auth for Artifact Registry pulls (one-time, as root):

```bash
sudo gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
```

This populates `/root/.docker/config.json`, which the Nomad Docker plugin reads to authenticate pulls. On a GCE VM with the default `cloud-platform` service-account scope, the credential helper uses metadata-server tokens and never expires.

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
cd nomad

# Deploy Traefik (load balancer)
nomad job run traefik.nomad.hcl

# Deploy IronClaw shards
nomad job run ironclaw.nomad.hcl
```

Verify:

```bash
# Health check through Traefik (skip cert verify for self-signed)
curl -sk https://<VM_IP_SSLIP>/health
# → {"status":"healthy","channel":"http"}
```

## Step 7: Deploy oauth2-proxy (Google SSO for Nomad UI)

Requires a Google OAuth client ID/secret with redirect URI `http://<VM_IP_SSLIP>:8646/oauth2/callback`.

Edit `oauth2-proxy.nomad.hcl` and fill in the placeholders, then:

```bash
nomad job run oauth2-proxy.nomad.hcl
```

Access Nomad UI at `http://<VM_IP_SSLIP>:8646` — requires `@nearone.org` or `@near.ai` Google login.

Direct access to port 4646 is blocked by the firewall. Traefik dashboard is accessible via SSH tunnel only:

```bash
gcloud compute ssh ironclaw-nomad-node --zone us-central1-a -- -L 8081:localhost:8081
# Then open http://localhost:8081/dashboard/
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
curl -sk https://<VM_IP_SSLIP>:9000/api/admin/users \
  -H "Authorization: Bearer GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"display_name": "Alice", "role": "member"}'
# → Returns one-time token

# User accesses their agent at:
# https://<VM_IP_SSLIP>:9000/?token=THEIR_TOKEN
```

For bulk user creation, see `nomad/tests/create-users.py`.

## Mock LLM (Stress Testing)

Uses [StacklokLabs/mockllm](https://github.com/StacklokLabs/mockllm) for unlimited-throughput testing without LLM rate limits.

```bash
# Build the mock image
cd nomad/mockllm
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
cd nomad/tests

# Infrastructure test (async, no LLM wait)
python3 stress-infra.py https://<VM_IP_SSLIP>

# Full pipeline test (sync, with LLM response)
python3 stress-test.py https://<VM_IP_SSLIP> WEBHOOK_SECRET

# Basic scale verification
python3 test-scale.py https://<VM_IP_SSLIP>
```

## File Layout

```
.
├── README.md                    # This file
├── CLUSTER.md                   # Live cluster details (IPs, URLs, credentials)
├── setup.sql                    # Database initialization (pgvector)
├── setup.sh                     # VM-side bootstrap helper
├── env.example                  # Example shard env vars
├── cloud-sql-proxy.service      # systemd unit for Cloud SQL proxy
├── ironclaw.service             # systemd unit for direct (non-Nomad) run
├── docs/
│   └── MULTITENANCY.md          # Scaling strategies (A/B/C)
├── terraform/                   # GCP infrastructure
│   ├── main.tf                  # Cloud SQL, Artifact Registry, GCE VM
│   ├── variables.tf             # Configurable parameters
│   └── outputs.tf               # Connection strings, IPs, commands
└── nomad/                       # Nomad orchestration
    ├── ironclaw.nomad.hcl       # Agent shards (main job)
    ├── traefik.nomad.hcl        # Load balancer
    ├── mockllm.nomad.hcl        # Mock LLM for testing
    ├── oauth2-proxy.nomad.hcl   # Google SSO for Nomad UI
    ├── mockllm/                 # Mock LLM Docker image
    │   ├── Dockerfile
    │   └── responses.yml
    ├── Dockerfile.slim          # IronClaw shard image
    ├── Dockerfile.worker        # Sandbox worker image (Python, Node, git)
    ├── deploy.sh                # Deploy script (--mock flag)
    └── tests/
        ├── create-users.py      # Bulk user creation
        ├── stress-test.py       # LLM stress test
        ├── stress-infra.py      # Infrastructure stress test
        └── test-scale.py        # Basic scale verification
```

## Known Limits

| Resource | Limit | Scope |
|----------|-------|-------|
| Webhook rate limit | 60 req/min | Per shard |
| NEAR AI staging API | 10 req/60s | Per API key |
| Gateway chat rate limit | 30 req/60s | Per user |
| Max SSE/WS connections | 100 | Per shard |

## Access Control

| Port | Service | Auth |
|------|---------|------|
| 443 | Webhook API (HTTPS) | HMAC-SHA256 |
| 9000 | Gateway UI (HTTPS) | Bearer token |
| 8646 | Nomad UI | Google SSO (@nearone.org, @near.ai) |
| 8081 | Traefik dashboard | SSH tunnel only |
| 4646 | Blocked | — |

TLS uses a self-signed cert for `<VM_IP>.sslip.io`. Browsers will show a security warning. For production, use a real domain with Let's Encrypt (Traefik has built-in support).

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
