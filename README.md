# IronClaw Sharded Multi-Tenant Deployment

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

<img width="1440" height="1906" alt="image" src="https://github.com/user-attachments/assets/4833f5f8-323d-4900-8822-9fb6d2bef06b" />


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

> **This repo is the deployment overlay only — it does not contain the IronClaw Rust source.** The slim Dockerfiles (`Dockerfile.slim` for the shard, `Dockerfile.worker.slim` for the sandbox worker) live at the root of the [IronClaw repo](https://github.com/nearai/ironclaw) alongside `Cargo.toml`. Build from a clone of that repo, not from this overlay.

The shard image is pulled from Artifact Registry at deploy time, not built on the VM. You can build either locally or, for faster native builds on the VM, directly on the Nomad host.

**Option A — Build on the Nomad VM** (recommended; native amd64, no cross-compile, no image upload over your ISP):

```bash
# From your local ironclaw checkout:
git archive --format=tar HEAD | \
  gcloud compute ssh ironclaw-nomad-node --zone us-central1-a --command \
    'rm -rf ~/ironclaw-build && mkdir -p ~/ironclaw-build && tar -xf - -C ~/ironclaw-build'

gcloud compute ssh ironclaw-nomad-node --zone us-central1-a --command '
  cd ~/ironclaw-build
  SHA=$(git rev-parse --short HEAD 2>/dev/null || echo local)
  SHARD=us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw
  WORKER=us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw-worker

  # For a long build that survives SSH drops, run detached with nohup:
  nohup bash -c "
    docker build -t $SHARD:$SHA -t $SHARD:latest -f Dockerfile.slim .         && \
    docker push $SHARD:$SHA && docker push $SHARD:latest                       && \
    docker build -t $WORKER:$SHA -t $WORKER:latest -f Dockerfile.worker.slim . && \
    docker push $WORKER:$SHA && docker push $WORKER:latest                     && \
    docker tag $WORKER:latest ironclaw-worker:latest
  " > ~/build.log 2>&1 &
  echo \"Build PID: \$!\"
'
```

**Option B — Build locally** (requires Docker buildx for linux/amd64 on arm64 Macs; slower):

```bash
# From your local ironclaw checkout:
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

IMAGE=us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw
TAG=$(git rev-parse --short HEAD)

docker build --platform linux/amd64 -t "$IMAGE:$TAG" -t "$IMAGE:latest" -f Dockerfile.slim .
docker push "$IMAGE:$TAG"
docker push "$IMAGE:latest"
```

First build takes ~10–15 minutes (Rust compilation); subsequent builds use cached dependency layers (~1–2 min).

The Nomad job (`nomad/ironclaw.nomad.hcl`) defaults to the `:latest` tag with `force_pull = true`. Pin to a specific SHA at deploy time:

```bash
nomad job run -var ironclaw_image="$IMAGE:$TAG" nomad/ironclaw.nomad.hcl
```

### Worker image (sandbox jobs)

The worker image is launched by the **IronClaw agent code itself** (not by Nomad) when it dispatches per-turn sandbox containers via the host Docker socket. The agent hardcodes the tag `ironclaw-worker:latest`, so the VM's local Docker daemon must have an image under that exact tag — Artifact Registry alone isn't enough.

Option A above already retags it on the VM. If you built locally:

```bash
WORKER=us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw-worker

docker build --platform linux/amd64 -t "$WORKER:$TAG" -t "$WORKER:latest" \
  -f Dockerfile.worker.slim .
docker push "$WORKER:$TAG"
docker push "$WORKER:latest"

gcloud compute ssh ironclaw-nomad-node --zone us-central1-a --command "
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

### Artifact Registry authentication

Nomad's Docker plugin reads `/root/.docker/config.json` to authenticate pulls (see the `plugin "docker" { auth { config = ... } }` block above). On this VM the config contains a static `auths` entry with a cached OAuth2 access token — **which expires after 1 hour**.

> ⚠️ **The credential-helper path is not used by the Nomad Docker plugin in this configuration.** Even though `/root/.docker/config.json` lists `credHelpers`, the plugin reads the static `auths` token and does not call the helper. If the token expires, `nomad job run` fails with `unauthorized: authentication failed` on every pull.

A refresh script is installed at `/usr/local/sbin/refresh-ar-docker-auth.sh` and runs from root's crontab every 30 minutes:

```cron
*/30 * * * * /usr/local/sbin/refresh-ar-docker-auth.sh >> /var/log/refresh-ar-docker-auth.log 2>&1
```

The script calls `gcloud auth print-access-token` (which uses the VM's metadata-server service-account credentials) and writes a fresh base64-encoded token into `/root/.docker/config.json`. To run it manually:

```bash
sudo /usr/local/sbin/refresh-ar-docker-auth.sh
```

The script itself is maintained in this repo at `scripts/refresh-ar-docker-auth.sh` — redeploy/re-apply Terraform to reinstall on a fresh node.

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

Store the secrets in a Nomad Variable (the job templates them in as `OAUTH2_PROXY_*` env vars at runtime — no editing of the HCL):

```bash
nomad var put nomad/jobs/oauth2-proxy \
  CLIENT_ID=<google-oauth-client-id>.apps.googleusercontent.com \
  CLIENT_SECRET=GOCSPX-... \
  COOKIE_SECRET=$(openssl rand -base64 32)
```

Then deploy:

```bash
nomad job run nomad/oauth2-proxy.nomad.hcl
```

The `--redirect-url` is still hardcoded in `nomad/oauth2-proxy.nomad.hcl` (currently the `34-69-64-144.sslip.io` host). If the VM IP or domain changes, edit that one line and redeploy.

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

Two mock LLM backends are available. Both bind `localhost:4010` on host networking, so they are **mutually exclusive** — `./deploy.sh --mock=<name>` purges the other before starting.

| Backend | Flag | Use when |
|---|---|---|
| [StacklokLabs/mockllm](https://github.com/StacklokLabs/mockllm) | `--mock=stacklok` | Zero-config canned responses. Fast throughput testing without realistic chat traffic. |
| [CopilotKit/llmock](https://github.com/CopilotKit/llmock) (aimock) | `--mock=llmock` | Fixture-driven responses matched on user message / model / tool name; SSE streaming with configurable latency & chunk size; chaos injection (500s, malformed JSON, mid-stream disconnects); record-replay against real APIs. |

### Stacklok mockllm (zero-config)

```bash
# Build once (local image):
cd nomad/mockllm && docker build -t mockllm:local .

# Switch to it:
./deploy.sh --mock=stacklok
```

### CopilotKit llmock / aimock

Uses the published image `ghcr.io/copilotkit/aimock:latest` — no local build.

```bash
./deploy.sh --mock=llmock
```

Fixture file lives at `nomad/llmock/fixtures.json` — edit and re-run `nomad job run nomad/llmock.nomad.hcl` to reload. See the [llmock README](https://github.com/CopilotKit/llmock) for the full fixture schema.

#### Testing tools and sandbox

The seed fixtures include two tool-call triggers for verifying that the shard can execute tools and dispatch sandbox worker containers:

| Send message containing | Tool called | What it tests |
|---|---|---|
| `echotest` | `echo` (built-in) | Tool-call round trip — no Docker needed |
| `jobtest` | `create_job` (sandbox) | Full sandbox dispatch — shard → Docker socket → `ironclaw-worker:latest` container |

Send via the gateway UI or webhook:

```bash
# Via webhook (replace WEBHOOK_SECRET with the live value from Nomad var)
curl -sk -X POST https://<VM_IP_SSLIP>/webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $(echo -n '{"content":"echotest","user_id":"USER_ID","wait_for_response":true}' \
    | openssl dgst -sha256 -hmac WEBHOOK_SECRET | sed 's/.* /sha256=/')" \
  -d '{"content":"echotest","user_id":"USER_ID","wait_for_response":true}'
```

The `echotest` fixture returns one tool call, the shard executes the `echo` tool, then the catch-all fixture returns a text response — ending the loop after exactly one tool execution.

The `jobtest` fixture calls `create_job`, which dispatches an `ironclaw-worker:latest` container via the mounted Docker socket. Requires `SANDBOX_ENABLED=true` (set by default via the Nomad Variable template) and `/var/run/docker.sock` mounted in the shard container.

**Important:** aimock matches `userMessage` as a **substring** against the **full conversation history**. Use unique trigger words (`echotest`, `jobtest`) that won't appear in tool output or previous messages. Test with a fresh user if the conversation history has accumulated prior test artifacts.

### Switch back to real LLM

```bash
./deploy.sh --real    # purges whichever mock is running, restores saved NEAR AI config
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
├── nomad/                       # Nomad orchestration
│   ├── ironclaw.nomad.hcl       # Agent shards (main job)
│   ├── traefik.nomad.hcl        # Load balancer
│   ├── mockllm.nomad.hcl        # Mock LLM: Stacklok mockllm (canned responses)
│   ├── llmock.nomad.hcl         # Mock LLM: CopilotKit llmock (fixture-driven)
│   ├── oauth2-proxy.nomad.hcl   # Google SSO for Nomad UI
│   ├── mockllm/                 # Stacklok mockllm Docker image + config
│   │   ├── Dockerfile
│   │   └── responses.yml
│   ├── llmock/                  # CopilotKit llmock fixtures
│   │   └── fixtures.json
│   ├── deploy.sh                # Deploy script (--mock flag)
│   └── tests/
│       ├── create-users.py      # Bulk user creation
│       ├── stress-test.py       # LLM stress test
│       ├── stress-infra.py      # Infrastructure stress test
│       └── test-scale.py        # Basic scale verification
└── scripts/                     # Maintenance scripts (installed on the VM)
    └── refresh-ar-docker-auth.sh  # Hourly-token refresher for Nomad pulls
```

> `Dockerfile.slim` and `Dockerfile.worker.slim` live at the root of the [IronClaw repo](https://github.com/nearai/ironclaw) — they need the Rust source tree as their build context, so they stay with the code.

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
