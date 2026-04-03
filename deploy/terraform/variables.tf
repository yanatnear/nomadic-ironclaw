variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources in"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone for the VM"
  type        = string
  default     = "us-central1-a"
}

variable "instance_name_prefix" {
  description = "Prefix for the Cloud SQL instance name"
  type        = string
  default     = "ironclaw-db"
}

variable "tier" {
  description = "The machine tier for the Cloud SQL instance. For 1,000 agents, db-custom-2-8192 or higher is recommended."
  type        = string
  default     = "db-custom-2-8192" # 2 vCPU, 8GB RAM
}

variable "disk_size_gb" {
  description = "Initial disk size in GB"
  type        = number
  default     = 50
}

variable "disk_autoresize_limit_gb" {
  description = "Maximum size the disk can auto-resize to (0 = unlimited)"
  type        = number
  default     = 500
}

variable "db_name" {
  description = "The name of the database to create"
  type        = string
  default     = "ironclaw"
}

variable "db_user" {
  description = "The name of the database user to create"
  type        = string
  default     = "ironclaw_app"
}

variable "vm_machine_type" {
  description = "Machine type for the Nomad node. e2-standard-4 (4 vCPU, 16GB) is good for 1,000 agents."
  type        = string
  default     = "e2-standard-4"
}

variable "nearai_api_key" {
  description = "The NearAI API key"
  type        = string
  sensitive   = true
}
