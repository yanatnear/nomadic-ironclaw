job "traefik" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "system"

  group "traefik" {
    network {
      port "http" {
        static = 80
      }
      port "https" {
        static = 443
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image        = "traefik:v2.10"
        network_mode = "host"
        volumes      = [
          "local/dynamic.yml:/etc/traefik/dynamic.yml",
          "local/cert.pem:/etc/traefik/certs/cert.pem",
          "local/key.pem:/etc/traefik/certs/key.pem",
        ]
        args = [
          "--api.insecure=true",
          "--api.dashboard=true",
          "--providers.nomad=true",
          "--providers.nomad.endpoint.address=http://127.0.0.1:4646",
          "--providers.file.filename=/etc/traefik/dynamic.yml",
          "--entrypoints.web.address=:80",
          "--entrypoints.web.http.redirections.entrypoint.to=websecure",
          "--entrypoints.web.http.redirections.entrypoint.scheme=https",
          "--entrypoints.websecure.address=:443",
          "--entrypoints.gateway.address=:9000",
          "--entrypoints.traefik.address=:8081",
          "--accesslog=true"
        ]
      }

      # TLS cert from Nomad Variables
      template {
        destination = "local/cert.pem"
        data        = <<EOH
{{ with nomadVar "nomad/jobs/traefik" }}{{ .TLS_CERT }}{{ end }}
EOH
      }

      template {
        destination = "local/key.pem"
        perms       = "0600"
        data        = <<EOH
{{ with nomadVar "nomad/jobs/traefik" }}{{ .TLS_KEY }}{{ end }}
EOH
      }

      # Dynamic config for TLS default cert
      template {
        destination = "local/dynamic.yml"
        data        = <<YAML
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/cert.pem
        keyFile: /etc/traefik/certs/key.pem
YAML
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
