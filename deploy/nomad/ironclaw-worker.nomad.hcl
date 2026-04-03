# IronClaw "Session Worker" Nomad Job Specification
#
# This configuration implements "Dispatched Session Workers" (Scenario 4).
# This is a 'batch' job designed to run exactly ONE interaction for ONE user 
# and then exit.
#
# Usage:
# nomad job dispatch ironclaw-worker -var user_id=452 -var message="What is my balance?"

job "ironclaw-worker" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "batch"

  parameterized {
    payload       = "forbidden"
    meta_required = ["user_id", "message"]
  }

  group "session-worker" {
    # Each turn gets its own short-lived container.
    task "ironclaw" {
      driver = "docker"

      config {
        image = "us-central1-docker.pkg.dev/nearone-ai-infra/ironclaw-repo/ironclaw:latest"
        
        # We pass the command to process a single message and exit.
        args = [
          "run", 
          "--message", "${NOMAD_META_message}",
          "--user-id", "${NOMAD_META_user_id}",
          "--cli-only"
        ]
      }

      env {
        # CRITICAL: We force the worker to be single-threaded (Scenario 2).
        # This reduces RAM and thread overhead by 90% per worker.
        TOKIO_WORKER_THREADS = "1"
        DATABASE_POOL_SIZE   = "1"
      }

      template {
        destination = "local/env"
        env         = true
        data        = <<EOH
{{ with secret "secrets/ironclaw" }}
DATABASE_URL="{{ .Data.database_url }}"
SECRETS_MASTER_KEY="{{ .Data.master_key }}"
{{ end }}
EOH
      }

      # Very small resource footprint — perfect for massive bursts of users.
      resources {
        cpu    = 500  # 0.5 Core
        memory = 256  # 256MB RAM (Enough for one turn's context)
      }
    }
  }
}
