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

# Firestore Database
resource "google_firestore_database" "default" {
  project     = var.project_id
  name        = var.database_name
  location_id = var.location_id
  type        = var.database_type
  mode        = var.database_mode

  delete_protection_enabled = var.delete_protection_enabled
}

# Firestore Collection (Document)
resource "google_firestore_document" "example" {
  for_each = var.documents

  project     = var.project_id
  database    = google_firestore_database.default.name
  collection  = each.value.collection
  document_id = each.value.document_id
  fields      = each.value.fields
}

# Firestore Index
resource "google_firestore_index" "custom_index" {
  for_each = var.custom_indexes

  project    = var.project_id
  database   = google_firestore_database.default.name
  collection = each.value.collection

  dynamic "fields" {
    for_each = each.value.fields
    content {
      field_path = fields.value.field_path
      order      = fields.value.order
    }
  }

  query_scope = each.value.query_scope
}

# Firestore Backup
resource "google_firestore_backup_schedule" "backup_schedule" {
  count = var.enable_backup_schedule ? 1 : 0

  project     = var.project_id
  database    = google_firestore_database.default.name
  location    = var.location_id
  backup_retention_days = var.backup_retention_days

  daily_recurrence {
    time = var.backup_time
  }
}

# Firestore Field Policy (Security)
resource "google_firestore_field" "field_policy" {
  for_each = var.field_policies

  project    = var.project_id
  database   = google_firestore_database.default.name
  collection = each.value.collection
  field      = each.value.field

  index_config {
    indexes {
      query_scope = each.value.query_scope
      order       = each.value.order
    }
  }

  ttl_config {
    state = each.value.ttl_enabled ? "ENABLED" : "DISABLED"
  }
}

# Firestore TTL Configuration (Auto-delete documents)
resource "google_firestore_document" "ttl_example" {
  for_each = var.ttl_documents

  project     = var.project_id
  database    = google_firestore_database.default.name
  collection  = each.value.collection
  document_id = each.value.document_id
  fields      = merge(
    each.value.fields,
    {
      "__name__" = {
        string_value = "${each.value.collection}/${each.value.document_id}"
      }
    }
  )
}

# Firestore Backups (On-Demand)
resource "google_firestore_backup" "on_demand_backup" {
  for_each = var.on_demand_backups

  project    = var.project_id
  database   = google_firestore_database.default.name
  location   = var.location_id
  backup_id  = each.value.backup_id
}

# Service Account for Firestore
resource "google_service_account" "firestore_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for Firestore"
}

# IAM Binding for Service Account
resource "google_project_iam_member" "firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.firestore_sa.email}"
}

resource "google_project_iam_member" "firestore_export" {
  project = var.project_id
  role    = "roles/datastore.importExportAdmin"
  member  = "serviceAccount:${google_service_account.firestore_sa.email}"
}

# Firestore Export to Cloud Storage
resource "google_firestore_backup" "export_backup" {
  for_each = var.export_backups

  project    = var.project_id
  database   = google_firestore_database.default.name
  location   = var.location_id
  backup_id  = each.value.backup_id
}

output "firestore_database_name" {
  description = "The name of the Firestore database"
  value       = google_firestore_database.default.name
}

output "firestore_service_account_email" {
  description = "Email of the Firestore service account"
  value       = google_service_account.firestore_sa.email
}
