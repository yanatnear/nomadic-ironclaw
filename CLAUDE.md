# CLAUDE.md

## Project overview
Deployment overlay for IronClaw (Rust agent platform) on GCP. Nomad orchestration, Traefik LB, Cloud SQL Postgres. The IronClaw source lives at ../ironclaw (separate repo).

## GCP / VM
- Project: `nearone-ai-infra`, VM: `ironclaw-nomad-node`, zone: `us-central1-a`
- SSH: `gcloud compute ssh ironclaw-nomad-node --zone us-central1-a --project nearone-ai-infra`
- SSH may timeout during Docker builds (4 vCPU saturated by Rust compile). Use `--ssh-flag="-o ConnectTimeout=30"`.
- After VM reset, Nomad restarts via systemd using `-config /etc/nomad.d/` (NOT `-dev` — we fixed the unit file).

## Nomad
- Secrets: `nomad var get nomad/jobs/ironclaw-shards` and `nomad/jobs/oauth2-proxy`
- `nomad job run` without a spec change won't restart allocs. To force a fresh image pull: `nomad job stop <job> && nomad job run <spec>`.
- HCL `file()` resolves relative to CWD of `nomad job run`, not the HCL file location. deploy.sh cd's to repo root for this reason.
- Go template `{{ or (.MISSING_KEY) "default" }}` doesn't work for absent nomadVar keys. Use `{{ if .KEY }}...{{ else }}...{{ end }}`.

## Docker / Images
- Shard image: `us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw:latest` (AR). Job uses `force_pull = true`.
- Worker image: `ironclaw-worker:latest` must exist as a LOCAL Docker tag on the VM (agent code hardcodes the tag).
- Docker socket mount: use Docker-native `config { volumes = ["/var/run/docker.sock:/var/run/docker.sock"] }`, NOT Nomad host-volume abstraction (volume/volume_mount). Requires `volumes { enabled = true }` in docker plugin config.
- AR auth: `/root/.docker/config.json` with a cron-refreshed OAuth token (see `scripts/refresh-ar-docker-auth.sh`).

## Building the shard image
- Source: `../ironclaw` repo, branch `feature/runtime-optimizations`
- Dockerfile: `Dockerfile.slim` (two-stage, ~45MB). NOT `Dockerfile` (full, cargo-chef + wasm-tools, ~30min).
- Upload: `git archive --format=tar HEAD | gcloud compute ssh ... --command 'tar -xf - -C ~/ironclaw-build'`
- Build on VM: `docker build -t $IMAGE:latest -f Dockerfile.slim .` (~28min cold, ~2min cached)
- Thin LTO is enabled (`lto = "thin"` in Cargo.toml) — linking alone takes 5-10 min on 4 vCPU.

## IronClaw sandbox detection
- `src/sandbox/detect.rs` checks for Docker: we patched it to try bollard socket connection BEFORE `which docker` CLI check (fix/sandbox-check branch). Without this, sandbox fails in containers without Docker CLI.
- `SANDBOX_ENABLED=true` env var required (defaults via nomadVar template with if/else fallback).
- `SANDBOX_IMAGE=ironclaw-worker:latest` env var may be needed.

## Networking
- Shards run on Docker bridge mode with dynamic ports. `extra_hosts = ["localhost:172.17.0.1"]` maps container localhost to Docker host for reaching mock LLM on port 4010.
- `HTTP_HOST=0.0.0.0` required for Traefik to reach the webhook channel (bridge port mapping needs 0.0.0.0 bind inside container).
- `GATEWAY_HOST=0.0.0.0` for gateway UI.
- Health check probes the gateway port (not webhook port) — `port = "gateway"`, path `/health`.
- Traefik `readTimeout=0` on gateway/websecure entrypoints for SSE.

## Mock LLM (llmock / aimock)
- Two backends: stacklok (`mockllm:local`, zero-config) and llmock (`ghcr.io/copilotkit/aimock:latest`, fixture-driven).
- Both use host networking on port 4010, mutually exclusive.
- `deploy.sh --mock=stacklok|llmock` / `--real` / `--status`
- IronClaw calls `/v1/chat/completions` (NOT `/v1/responses`).
- aimock `userMessage` match is substring (not regex). `sequenceIndex` resets per request.
- aimock matches against FULL conversation history — use unique trigger words to avoid cross-fixture contamination.

## deploy.sh
- cd's to repo root (not nomad/) so file() paths work.
- `--image TAG` sets `NOMAD_VAR_ironclaw_image` for the deploy.
- `--mock=NAME` required (no bare `--mock`).

## Testing
- Stress scripts require `HTTP_WEBHOOK_SECRET` as arg or env var (no default — rotated).
- `INSECURE=1` env var to skip TLS verify for self-signed sslip.io cert.
- Webhook payload: `{"content": "...", "user_id": "...", "wait_for_response": true}`
