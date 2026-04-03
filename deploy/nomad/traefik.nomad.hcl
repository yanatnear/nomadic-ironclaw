job "traefik" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "system"

  group "traefik" {
    network {
      port "http" {
        static = 80
      }
      port "api" {
        static = 8081
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image        = "traefik:v2.10"
        network_mode = "host"
        args = [
          "--api.insecure=true",
          "--api.dashboard=true",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://127.0.0.1:4646",
          "--entrypoints.web.address=:80",
          "--entrypoints.traefik.address=:8081",
          "--entrypoints.gateway.address=:9000",
          "--accesslog=true"
        ]
      }

      resources {
        cpu    = 300
        memory = 128
      }

      service {
        name     = "traefik"
        provider = "nomad"
        port     = "http"
        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
