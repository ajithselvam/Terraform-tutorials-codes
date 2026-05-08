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

# Cloud KMS Key Ring
resource "google_kms_key_ring" "default" {
  name     = var.key_ring_name
  location = var.kms_location
  project  = var.project_id
}

# Cloud KMS Crypto Key
resource "google_kms_crypto_key" "default" {
  name            = var.crypto_key_name
  key_ring        = google_kms_key_ring.default.id
  rotation_period = var.rotation_period
  version_template {
    algorithm = var.algorithm
  }

  labels = var.labels

  depends_on = [
    google_kms_key_ring.default
  ]
}

# Additional Crypto Keys
resource "google_kms_crypto_key" "additional_keys" {
  for_each = var.additional_crypto_keys

  name     = each.value.name
  key_ring = google_kms_key_ring.default.id
  rotation_period = each.value.rotation_period
  version_template {
    algorithm = each.value.algorithm
  }

  labels = each.value.labels
}

# Cloud KMS Crypto Key IAM - Encrypter/Decrypter
resource "google_kms_crypto_key_iam_member" "crypto_key_encrypter_decrypter" {
  for_each = toset(var.encrypter_decrypter_members)

  crypto_key_id = google_kms_crypto_key.default.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.value
}

# Cloud KMS Crypto Key IAM - Viewer
resource "google_kms_crypto_key_iam_member" "crypto_key_viewer" {
  for_each = toset(var.viewer_members)

  crypto_key_id = google_kms_crypto_key.default.id
  role          = "roles/cloudkms.viewer"
  member        = each.value
}

# Cloud KMS Key Ring IAM - Admin
resource "google_kms_key_ring_iam_member" "key_ring_admin" {
  for_each = toset(var.admin_members)

  key_ring_id = google_kms_key_ring.default.id
  role        = "roles/cloudkms.admin"
  member      = each.value
}

# Service Account for KMS Operations
resource "google_service_account" "kms_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for KMS Operations"
  project      = var.project_id
}

# IAM Binding for Service Account
resource "google_kms_crypto_key_iam_member" "kms_sa_encrypter_decrypter" {
  crypto_key_id = google_kms_crypto_key.default.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.kms_sa.email}"
}

# Encrypt/Decrypt Data (example using null_resource)
resource "google_kms_secret_ciphertext" "encrypted_secret" {
  crypto_key = google_kms_crypto_key.default.id
  plaintext  = base64encode(var.plaintext_secret)
}

# Decrypt Data
data "google_kms_secret" "decrypted_secret" {
  crypto_key      = google_kms_crypto_key.default.id
  ciphertext      = google_kms_secret_ciphertext.encrypted_secret.ciphertext
}

# Cloud KMS Key Versions
resource "google_kms_crypto_key_version" "key_version" {
  crypto_key = google_kms_crypto_key.default.id
  state      = var.key_version_state
}

# Cloud KMS Automation
resource "google_kms_crypto_key_iam_binding" "crypto_key_binding" {
  crypto_key_id = google_kms_crypto_key.default.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  members       = var.encrypted_data_members
}

# Monitoring Alert for KMS
resource "google_monitoring_alert_policy" "kms_alert" {
  count        = var.enable_monitoring_alert ? 1 : 0
  display_name = "${var.crypto_key_name}-alert"
  combiner     = "OR"
  project      = var.project_id

  conditions {
    display_name = "High KMS API error rate"

    condition_threshold {
      filter          = "metric.type=\"cloudkms.googleapis.com/api/crypto_key_decrypt_error_count\" AND resource.labels.key_id=\"${google_kms_crypto_key.default.name}\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.error_threshold
    }
  }

  notification_channels = var.notification_channels
}

# Cloud KMS Automatic Key Rotation
resource "google_kms_crypto_key_version" "auto_rotation" {
  crypto_key = google_kms_crypto_key.default.id
  state      = "ENABLED"
}

# Logging for KMS
resource "google_logging_project_sink" "kms_audit_logs" {
  count       = var.enable_audit_logging ? 1 : 0
  name        = "${var.key_ring_name}-audit-logs"
  destination = "storage.googleapis.com/${google_storage_bucket.audit_logs[0].name}"
  filter      = "protoPayload.methodName=\"cloudkms.googleapis.com/CreateCryptoKey\" OR protoPayload.methodName=\"cloudkms.googleapis.com/Encrypt\" OR protoPayload.methodName=\"cloudkms.googleapis.com/Decrypt\""
  project     = var.project_id

  unique_writer_identity = true
}

# Storage bucket for audit logs
resource "google_storage_bucket" "audit_logs" {
  count    = var.enable_audit_logging ? 1 : 0
  name     = "${var.project_id}-kms-audit-logs-${data.google_client_config.default.project}"
  location = var.kms_location
  project  = var.project_id

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}

# IAM binding for audit log sink
resource "google_storage_bucket_iam_member" "audit_logs_writer" {
  count  = var.enable_audit_logging ? 1 : 0
  bucket = google_storage_bucket.audit_logs[0].name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.kms_audit_logs[0].writer_identity
  project = var.project_id
}

# Data source for current GCP config
data "google_client_config" "default" {}

output "key_ring_name" {
  description = "Name of the KMS Key Ring"
  value       = google_kms_key_ring.default.name
}

output "crypto_key_id" {
  description = "ID of the KMS Crypto Key"
  value       = google_kms_crypto_key.default.id
}

output "crypto_key_name" {
  description = "Name of the KMS Crypto Key"
  value       = google_kms_crypto_key.default.name
}

output "kms_service_account_email" {
  description = "Email of the KMS service account"
  value       = google_service_account.kms_sa.email
}

output "encrypted_secret" {
  description = "Encrypted secret ciphertext"
  value       = google_kms_secret_ciphertext.encrypted_secret.ciphertext
  sensitive   = true
}
