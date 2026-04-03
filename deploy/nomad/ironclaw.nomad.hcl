job "ironclaw-shards" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "service"

  group "agent-shard" {
    count = 10

    network {
      port "http" {
        to = 8080
      }
      port "gateway" {
        to = 9000
      }
    }

    task "ironclaw" {
      driver = "docker"

      config {
        image      = "ironclaw:local"
        force_pull = false
        ports      = ["http", "gateway"]
      }

      env {
        AGENT_MULTI_TENANT   = "true"
        HTTP_PORT            = "${NOMAD_PORT_http}"
        GATEWAY_HOST         = "0.0.0.0"
        GATEWAY_PORT         = "${NOMAD_PORT_gateway}"
        TOKIO_WORKER_THREADS = "1"
        DATABASE_POOL_SIZE   = "5"
      }

      # Secrets injected from Nomad Variables.
      # Store them once with:
      #   nomad var put nomad/jobs/ironclaw-shards \
      #     NEARAI_API_KEY=sk-... \
      #     NEARAI_BASE_URL=https://private-chat-stg.near.ai \
      #     NEARAI_MODEL=Qwen/Qwen3-30B-A3B-Instruct-2507 \
      #     DATABASE_URL='postgres://...' \
      #     SECRETS_MASTER_KEY=$(openssl rand -hex 32) \
      #     GATEWAY_ADMIN_TOKEN=$(openssl rand -hex 24) \
      #     HTTP_WEBHOOK_SECRET=$(openssl rand -hex 16)
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
GATEWAY_ADMIN_TOKEN={{ .GATEWAY_ADMIN_TOKEN }}
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
          "traefik.http.routers.ironclaw.entrypoints=web",
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
        ]
      }
    }
  }
}
