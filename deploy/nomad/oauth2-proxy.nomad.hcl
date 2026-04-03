job "oauth2-proxy" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "system"

  group "proxy" {
    network {
      port "http" {
        static = 8646
      }
    }

    task "oauth2-proxy" {
      driver = "docker"

      config {
        image        = "quay.io/oauth2-proxy/oauth2-proxy:v7.8.1"
        network_mode = "host"
        args = [
          "--http-address=0.0.0.0:8646",
          "--provider=google",
          "--email-domain=nearone.org",
          "--email-domain=near.ai",
          "--upstream=http://127.0.0.1:4646",
          "--redirect-url=http://<VM_IP_SSLIP>:8646/oauth2/callback",
          "--cookie-secret=<python3 -c 'import os,base64;print(base64.b64encode(os.urandom(32)).decode())'>",
          "--cookie-secure=false",
          "--client-id=<GOOGLE_OAUTH_CLIENT_ID>",
          "--client-secret=<GOOGLE_OAUTH_CLIENT_SECRET>",
          "--skip-provider-button=true",
        ]
      }

      resources {
        cpu    = 100
        memory = 64
      }

      service {
        name     = "oauth2-proxy"
        provider = "nomad"
        port     = "http"

        check {
          type     = "http"
          path     = "/ping"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
