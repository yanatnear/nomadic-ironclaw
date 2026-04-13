terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Generate a random suffix to ensure globally unique instance names
resource "random_id" "db_name_suffix" {
  byte_length = 4
}

# Generate a secure random password for the database user
resource "random_password" "db_password" {
  length  = 24
  special = false # Avoid special characters that might complicate URL encoding
}

# Generate a secure 32-byte hex key for agent secret encryption
resource "random_id" "secrets_master_key" {
  byte_length = 32
}

# Generate a secure admin token for the Gateway API
resource "random_id" "gateway_admin_token" {
  byte_length = 24
}

# ── Artifact Registry (Image Hosting) ──────────────────────────────

# Google Artifact Registry for IronClaw Docker images
resource "google_artifact_registry_repository" "ironclaw_repo" {
  location      = var.region
  repository_id = var.instance_name_prefix == "ironclaw-db" ? "ironclaw-repo" : "${var.instance_name_prefix}-repo"
  description   = "Docker repository for IronClaw images"
  format        = "DOCKER"
}

# ── Database Resources ────────────────────────────────────────────────

# Cloud SQL Instance (PostgreSQL 15+)
resource "google_sql_database_instance" "ironclaw_db_instance" {
  name             = "${var.instance_name_prefix}-${random_id.db_name_suffix.hex}"
  database_version = "POSTGRES_15"
  region           = var.region

  settings {
    tier = var.tier

    # GCP-level delete guard: blocks deletion via Console, API, and gcloud.
    # Complements the Terraform-level `deletion_protection` below.
    deletion_protection_enabled = true

    # Storage settings
    disk_type             = "PD_SSD"
    disk_size             = var.disk_size_gb
    disk_autoresize       = true
    disk_autoresize_limit = var.disk_autoresize_limit_gb

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00" # UTC
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled = true # Set to false if using Private IP only

      # For production, restrict this to your Nomad cluster IPs or use Private IP
      authorized_networks {
        name  = "all"
        value = "0.0.0.0/0"
      }
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = true
    }
  }

  # Terraform-level delete guard: blocks `terraform destroy` and any apply
  # that would force replacement. Flip to false only when intentionally
  # tearing the instance down.
  deletion_protection = true
}

# The IronClaw Database
resource "google_sql_database" "ironclaw_db" {
  name     = var.db_name
  instance = google_sql_database_instance.ironclaw_db_instance.name
}

# The IronClaw User
resource "google_sql_user" "ironclaw_user" {
  name     = var.db_user
  instance = google_sql_database_instance.ironclaw_db_instance.name
  password = random_password.db_password.result
}

# ── Compute Resources (Nomad Node) ───────────────────────────────────

# Firewall rule to allow SSH, Traefik, IronClaw, and SSO traffic.
#
# Port map (must stay in sync with CLUSTER.md and nomad/traefik.nomad.hcl):
#   22   SSH
#   80   Traefik HTTP → HTTPS redirect
#   443  Traefik HTTPS (webhook API)
#   8080 IronClaw HTTP (direct, non-Traefik)
#   9000 Gateway UI (HTTPS via Traefik)
#   9001 Gateway UI (HTTP via Traefik, `gateway-http` entrypoint)
#   8646 oauth2-proxy (Google SSO → Nomad UI)
#
# Blocked by omission: 4646 (Nomad API), 8081 (Traefik dashboard — SSH tunnel only).
resource "google_compute_firewall" "ironclaw_firewall" {
  name    = "ironclaw-access"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "8080", "9000", "9001", "8646"]
  }

  source_ranges = ["0.0.0.0/0"] # For production, restrict this to your IP
}

# The Nomad + IronClaw VM
resource "google_compute_instance" "nomad_node" {
  name         = "ironclaw-nomad-node"
  machine_type = var.vm_machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 100 # Larger disk for Docker images and logs
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Include this block to give the VM a public IP
    }
  }

  # Startup script: install Docker + Nomad, write a production nomad.hcl,
  # and start Nomad as a systemd service (combined server+client, single node).
  #
  # This matches the live config on ironclaw-nomad-node. The previous version
  # ran `nomad agent -dev` which does NOT load /etc/nomad.d/ and breaks the
  # docker plugin's `volumes { enabled = true }` setting required for sandbox jobs.
  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -e
    apt-get update
    apt-get install -y docker.io unzip wget ca-certificates curl gnupg

    # Install Nomad from HashiCorp apt repo
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    apt-get update && apt-get install -y nomad

    # Write Nomad config. The `host_volume "docker-sock"` lets shard jobs
    # mount /var/run/docker.sock to dispatch sandbox worker containers.
    # The docker plugin block MUST live in this file (Nomad may not pick
    # up the plugin stanza from a separate HCL).
    mkdir -p /etc/nomad.d /opt/nomad/data
    cat > /etc/nomad.d/nomad.hcl <<'HCL'
    data_dir  = "/opt/nomad/data"
    bind_addr = "0.0.0.0"

    server {
      enabled          = true
      bootstrap_expect = 1
    }

    client {
      enabled = true
      servers = ["127.0.0.1"]

      host_volume "docker-sock" {
        path      = "/var/run/docker.sock"
        read_only = false
      }
    }

    plugin "docker" {
      config {
        auth {
          config = "/root/.docker/config.json"
        }
        allow_privileged = true
        volumes {
          enabled = true
        }
      }
    }
    HCL

    systemctl enable --now docker
    systemctl enable --now nomad

    echo "Nomad node setup complete"
  EOT

  service_account {
    scopes = ["cloud-platform"]
  }

  tags = ["ironclaw-nomad"]

  # The live VM was bootstrapped from an earlier version of this script and
  # has since been hand-configured (Docker images built, Nomad vars set, TLS
  # cert loaded). Ignore changes to fields that would force replacement —
  # recreation would wipe all of that. Remove these lines only when intentionally
  # rebuilding the VM.
  lifecycle {
    ignore_changes = [
      metadata_startup_script,
      boot_disk,
    ]
  }
}
