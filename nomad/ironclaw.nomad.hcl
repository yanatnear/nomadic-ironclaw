# Shard image is pulled from the Artifact Registry repo provisioned by
# Terraform (us-central1-docker.pkg.dev/<project>/ironclaw-repo/ironclaw).
# Override the tag at deploy time:
#
#   nomad job run -var ironclaw_image=...ironclaw:<sha> ironclaw.nomad.hcl
#
# Pull auth comes from the Docker plugin's `auth { config = "/root/.docker/config.json" }`
# block in /etc/nomad.d/nomad.hcl, populated once per VM by:
#   gcloud auth configure-docker us-central1-docker.pkg.dev
variable "ironclaw_image" {
  type        = string
  description = "Full image reference for the IronClaw shard container."
  default     = "us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw:latest"
}

variable "shard_count" {
  type        = number
  description = "Number of shard allocations to run."
  default     = 10
}

job "ironclaw-shards" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "service"

  group "agent-shard" {
    count = var.shard_count

    network {
      port "http" {
        to = 8080
      }
      port "gateway" {
        to = 9000
      }
      port "orchestrator" {}
    }

    task "ironclaw" {
      driver = "docker"

      config {
        image      = var.ironclaw_image
        force_pull = true
        ports      = ["http", "gateway", "orchestrator"]
        # Map localhost inside the container to the Docker host,
        # so http://localhost:4010 reaches the mockllm Nomad job.
        extra_hosts = ["localhost:172.17.0.1"]
      }

      env {
        AGENT_MULTI_TENANT   = "true"
        # HTTP webhook channel binds to 127.0.0.1 by default (security hardening);
        # override to 0.0.0.0 so Nomad's docker-proxy can reach it from the host.
        HTTP_HOST            = "0.0.0.0"
        HTTP_PORT            = "${NOMAD_PORT_http}"
        GATEWAY_HOST         = "0.0.0.0"
        GATEWAY_PORT         = "${NOMAD_PORT_gateway}"
        ORCHESTRATOR_PORT    = "${NOMAD_PORT_orchestrator}"
        TOKIO_WORKER_THREADS = "1"
        DATABASE_POOL_SIZE   = "5"
      }

      # Secrets injected from Nomad Variables.
      #
      # Production (NEAR AI staging):
      #   nomad var put nomad/jobs/ironclaw-shards \
      #     NEARAI_API_KEY=sk-... \
      #     NEARAI_BASE_URL=https://private-chat-stg.near.ai \
      #     NEARAI_MODEL=Qwen/Qwen3-30B-A3B-Instruct-2507 \
      #     DATABASE_URL='postgres://...' \
      #     SECRETS_MASTER_KEY=$(openssl rand -hex 32) \
      #     GATEWAY_ADMIN_TOKEN=$(openssl rand -hex 24) \
      #     HTTP_WEBHOOK_SECRET=$(openssl rand -hex 16)
      #
      # Mock LLM (for stress testing — requires mockllm.nomad.hcl running):
      #   nomad var put -force nomad/jobs/ironclaw-shards \
      #     NEARAI_API_KEY=mock-key \
      #     NEARAI_BASE_URL=http://localhost:4010 \
      #     NEARAI_MODEL=mock-model \
      #     DATABASE_URL='postgres://...' \
      #     SECRETS_MASTER_KEY=<same-as-production> \
      #     GATEWAY_ADMIN_TOKEN=<same-as-production> \
      #     HTTP_WEBHOOK_SECRET=<same-as-production>
      template {
        destination = "secrets/env"
        env         = true
        data        = <<EOH
{{ with nomadVar "nomad/jobs/ironclaw-shards" }}
NEARAI_API_KEY={{ .NEARAI_API_KEY }}
NEARAI_BASE_URL={{ .NEARAI_BASE_URL }}
NEARAI_MODEL={{ .NEARAI_MODEL }}
DATABASE_URL={{ .DATABASE_URL }}
SECRETS_MASTER_KEY={{ .SECRETS_MASTER_KEY }}
GATEWAY_AUTH_TOKEN={{ .GATEWAY_ADMIN_TOKEN }}
HTTP_WEBHOOK_SECRET={{ .HTTP_WEBHOOK_SECRET }}
{{ end }}
EOH
      }

      resources {
        cpu    = 500
        memory = 512
      }

      service {
        name     = "ironclaw-shard"
        provider = "nomad"
        port     = "http"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.ironclaw.rule=PathPrefix(`/`)",
          "traefik.http.routers.ironclaw.entrypoints=websecure",
          "traefik.http.routers.ironclaw.tls=true",
        ]

        check {
          type     = "http"
          path     = "/health"
          interval = "10s"
          timeout  = "2s"
        }
      }

      service {
        name     = "ironclaw-gateway"
        provider = "nomad"
        port     = "gateway"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.gateway.rule=PathPrefix(`/`)",
          "traefik.http.routers.gateway.entrypoints=gateway",
          "traefik.http.routers.gateway.tls=true",
          "traefik.http.routers.gateway-http.rule=PathPrefix(`/`)",
          "traefik.http.routers.gateway-http.entrypoints=gateway-http",
          "traefik.http.services.ironclaw-gateway.loadbalancer.sticky.cookie.name=ironclaw-shard",
          "traefik.http.services.ironclaw-gateway.loadbalancer.sticky.cookie.httpOnly=true",
        ]
      }
    }
  }
}
