terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Cloud SQL Instance
resource "google_sql_database_instance" "default" {
  name             = var.instance_name
  database_version = var.database_version
  region           = var.region

  settings {
    tier              = var.machine_tier
    availability_type = var.availability_type
    disk_type         = var.disk_type
    disk_size         = var.disk_size
    disk_autoresize   = var.disk_autoresize

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = var.backup_retention_days
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled    = true
      private_network = google_compute_network.vpc.id
      require_ssl     = true

      authorized_networks {
        name  = "office"
        value = var.office_cidr
      }
    }

    database_flags {
      name  = "max_connections"
      value = "100"
    }

    user_labels = var.labels
  }

  deletion_protection = var.deletion_protection

  depends_on = [
    google_service_networking_connection.private_vpc_connection
  ]
}

# Database
resource "google_sql_database" "database" {
  name     = var.database_name
  instance = google_sql_database_instance.default.name

  depends_on = [
    google_sql_database_instance.default
  ]
}

# Root User Password
resource "random_password" "root_password" {
  length  = 16
  special = true
}

# Database User
resource "google_sql_user" "root" {
  name     = var.db_user
  instance = google_sql_database_instance.default.name
  password = random_password.root_password.result
  type     = "BUILT_IN"
}

# Additional Database User
resource "google_sql_user" "app_user" {
  count    = var.create_app_user ? 1 : 0
  name     = var.app_user_name
  instance = google_sql_database_instance.default.name
  password = random_password.root_password.result
  type     = "BUILT_IN"
}

# VPC Network
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
}

# Private Service Connection
resource "google_compute_global_address" "private_ip_address" {
  name          = "${var.instance_name}-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# Cloud SQL Backup
resource "google_sql_backup_run" "default" {
  instance = google_sql_database_instance.default.id
  type     = "ON_DEMAND"

  depends_on = [
    google_sql_database_instance.default
  ]
}
