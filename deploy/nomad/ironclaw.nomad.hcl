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
        TOKIO_WORKER_THREADS = "2"
        DATABASE_POOL_SIZE   = "5"
        
        # Secrets — replace with real values before deploying.
        # In production, use Nomad Vault integration or template stanzas.
        NEARAI_API_KEY       = "<your-nearai-api-key>"
        NEARAI_BASE_URL      = "https://private-chat-stg.near.ai"
        NEARAI_MODEL         = "Qwen/Qwen3-30B-A3B-Instruct-2507"
        DATABASE_URL         = "<postgres-connection-string>?sslmode=disable"
        SECRETS_MASTER_KEY   = "<generate-with-openssl-rand-hex-32>"
        GATEWAY_ADMIN_TOKEN  = "<generate-with-openssl-rand-hex-24>"
        HTTP_WEBHOOK_SECRET  = "<generate-with-openssl-rand-hex-16>"
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
