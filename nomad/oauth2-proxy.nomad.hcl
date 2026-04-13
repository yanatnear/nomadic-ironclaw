job "oauth2-proxy" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "system"

  group "proxy" {
    network {
      port "https" {
        static = 8646
      }
    }

    task "oauth2-proxy" {
      driver = "docker"

      config {
        image        = "quay.io/oauth2-proxy/oauth2-proxy:v7.8.1"
        network_mode = "host"
        volumes      = [
          "local/cert.pem:/etc/oauth2-proxy/cert.pem",
          "local/key.pem:/etc/oauth2-proxy/key.pem",
        ]
        # Non-secret flags only. Secrets (CLIENT_ID, CLIENT_SECRET,
        # COOKIE_SECRET) come in as OAUTH2_PROXY_* env vars rendered
        # from the Nomad Variable template below — oauth2-proxy reads
        # any flag from its env-var equivalent automatically.
        args = [
          "--https-address=0.0.0.0:8646",
          "--http-address=",
          "--tls-cert-file=/etc/oauth2-proxy/cert.pem",
          "--tls-key-file=/etc/oauth2-proxy/key.pem",
          "--provider=google",
          "--email-domain=nearone.org",
          "--email-domain=near.ai",
          "--upstream=http://127.0.0.1:4646",
          "--upstream-timeout=0s",
          "--flush-interval=200ms",
          "--redirect-url=https://34-69-64-144.sslip.io:8646/oauth2/callback",
          "--cookie-secure=true",
          "--skip-provider-button=true",
        ]
      }

      # Secrets injected from Nomad Variables.
      #
      # Provision once per cluster:
      #   nomad var put nomad/jobs/oauth2-proxy \
      #     CLIENT_ID=<google-oauth-client-id>.apps.googleusercontent.com \
      #     CLIENT_SECRET=GOCSPX-... \
      #     COOKIE_SECRET=$(openssl rand -base64 32)
      template {
        destination = "secrets/env"
        env         = true
        data        = <<EOH
{{ with nomadVar "nomad/jobs/oauth2-proxy" }}
OAUTH2_PROXY_CLIENT_ID={{ .CLIENT_ID }}
OAUTH2_PROXY_CLIENT_SECRET={{ .CLIENT_SECRET }}
OAUTH2_PROXY_COOKIE_SECRET={{ .COOKIE_SECRET }}
{{ end }}
EOH
      }

      # TLS cert from Nomad Variables (same cert as Traefik)
      template {
        destination = "local/cert.pem"
        data        = <<EOH
{{ with nomadVar "nomad/jobs/traefik" }}{{ .TLS_CERT }}{{ end }}
EOH
      }

      template {
        destination = "local/key.pem"
        perms       = "0644"
        data        = <<EOH
{{ with nomadVar "nomad/jobs/traefik" }}{{ .TLS_KEY }}{{ end }}
EOH
      }

      resources {
        cpu    = 100
        memory = 64
      }

      service {
        name     = "oauth2-proxy"
        provider = "nomad"
        port     = "https"

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
