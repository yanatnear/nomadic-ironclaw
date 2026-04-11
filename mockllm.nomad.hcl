job "mockllm" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "system"

  group "mock" {
    network {
      port "http" {
        static = 4010
      }
    }

    task "mockllm" {
      driver = "docker"

      config {
        image        = "mockllm:local"
        force_pull   = false
        network_mode = "host"
      }

      resources {
        cpu    = 200
        memory = 128
      }

      service {
        name     = "mockllm"
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
