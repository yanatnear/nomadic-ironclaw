# CopilotKit/llmock (aimock) — sophisticated mock LLM backend.
#
# Alternative to mockllm.nomad.hcl (StacklokLabs/mockllm). The two are
# mutually exclusive: both bind static port 4010 on host networking.
# deploy.sh purges one before starting the other.
#
# Fixture file is templated from nomad/llmock/fixtures.json at deploy
# time and mounted into the container at /fixtures. Edit that file and
# re-run `nomad job run nomad/llmock.nomad.hcl` to reload.
#
# See: https://github.com/CopilotKit/llmock

job "llmock" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "system"

  group "mock" {
    network {
      port "http" {
        static = 4010
      }
    }

    task "llmock" {
      driver = "docker"

      config {
        image        = "ghcr.io/copilotkit/aimock:latest"
        force_pull   = true
        network_mode = "host"
        volumes      = [
          "local/fixtures:/fixtures",
        ]
        args = [
          "--host", "0.0.0.0",
          "--port", "4010",
          "--fixtures", "/fixtures",
          "--log-level", "debug",
        ]
      }

      # Fixture content read from nomad/llmock/fixtures.json at job-submit
      # time. Edit that file and re-run `nomad job run nomad/llmock.nomad.hcl`
      # (from the repo root) to reload responses. For live-reload during
      # tests, see aimock's --watch flag — not enabled here to keep the
      # spec simple.
      template {
        destination = "local/fixtures/default.json"
        data        = file("nomad/llmock/fixtures.json")
      }

      resources {
        cpu    = 200
        memory = 128
      }

      service {
        name     = "llmock"
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
