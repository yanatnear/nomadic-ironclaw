output "instance_name" {
  description = "The name of the Cloud SQL instance"
  value       = google_sql_database_instance.ironclaw_db_instance.name
}

output "instance_ip_address" {
  description = "The IPv4 address of the Cloud SQL instance"
  value       = google_sql_database_instance.ironclaw_db_instance.public_ip_address
}

output "database_url" {
  description = "The connection string for IronClaw (.env.nomad / Vault)"
  value       = "postgres://${google_sql_user.ironclaw_user.name}:${random_password.db_password.result}@${google_sql_database_instance.ironclaw_db_instance.public_ip_address}:5432/${google_sql_database.ironclaw_db.name}"
  sensitive   = true
}

output "psql_command" {
  description = "Command to connect via psql (useful for running setup.sql)"
  value       = "psql \"postgres://postgres@${google_sql_database_instance.ironclaw_db_instance.public_ip_address}:5432/${google_sql_database.ironclaw_db.name}\""
}

output "nomad_ui_url" {
  description = "The URL for the Nomad Web UI"
  value       = "http://${google_compute_instance.nomad_node.network_interface[0].access_config[0].nat_ip}:4646"
}

output "vm_public_ip" {
  description = "Public IP of the Nomad node"
  value       = google_compute_instance.nomad_node.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  description = "Command to SSH into the Nomad node"
  value       = "gcloud compute ssh ${google_compute_instance.nomad_node.name} --zone ${google_compute_instance.nomad_node.zone}"
}

output "nomad_env_block" {
  description = "Copy and paste these into your Nomad job environment (local/env template)"
  sensitive   = true
  value       = <<EOT
NEARAI_API_KEY      = "${var.nearai_api_key}"
DATABASE_URL        = "postgres://${google_sql_user.ironclaw_user.name}:${random_password.db_password.result}@${google_sql_database_instance.ironclaw_db_instance.public_ip_address}:5432/${google_sql_database.ironclaw_db.name}"
SECRETS_MASTER_KEY  = "${random_id.secrets_master_key.hex}"
GATEWAY_ADMIN_TOKEN = "${random_id.gateway_admin_token.hex}"
EOT
}

output "artifact_registry_url" {
  description = "The full URL for your private Docker registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.ironclaw_repo.name}"
}
