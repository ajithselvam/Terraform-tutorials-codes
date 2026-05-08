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

# Cloud Storage Bucket
resource "google_storage_bucket" "default" {
  name          = var.bucket_name
  location      = var.location
  storage_class = var.storage_class
  project       = var.project_id

  uniform_bucket_level_access = true

  versioning {
    enabled = var.enable_versioning
  }

  lifecycle_rule {
    condition {
      age = var.delete_age_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = var.archive_age_days
    }
    action {
      type          = "SetStorageClass"
      storage_class = ["COLDLINE"]
    }
  }

  labels = var.labels

  public_access_prevention = var.public_access_prevention
}

# Bucket IAM Binding for public read access (if needed)
resource "google_storage_bucket_iam_member" "public_read" {
  count  = var.make_public ? 1 : 0
  bucket = google_storage_bucket.default.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Bucket IAM Binding for service account
resource "google_storage_bucket_iam_member" "service_account_access" {
  bucket = google_storage_bucket.default.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.storage_sa.email}"
}

# Service Account for Cloud Storage
resource "google_service_account" "storage_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for Cloud Storage"
}

# Upload files to bucket
resource "google_storage_bucket_object" "default" {
  for_each = toset(var.bucket_objects)

  name   = each.value
  bucket = google_storage_bucket.default.name
  source = each.value
}

# Bucket Notification (Pub/Sub)
resource "google_storage_notification" "bucket_notification" {
  count         = var.enable_notifications ? 1 : 0
  bucket        = google_storage_bucket.default.name
  payload_format = "JSON_API_V1"
  topic         = google_pubsub_topic.bucket_notification[0].id
  event_types   = var.notification_events

  depends_on = [
    google_pubsub_topic.bucket_notification
  ]
}

# Pub/Sub Topic for notifications
resource "google_pubsub_topic" "bucket_notification" {
  count = var.enable_notifications ? 1 : 0
  name  = "${var.bucket_name}-notification"
}

# Pub/Sub Subscription
resource "google_pubsub_subscription" "bucket_notification" {
  count   = var.enable_notifications ? 1 : 0
  name    = "${var.bucket_name}-subscription"
  topic   = google_pubsub_topic.bucket_notification[0].name
  ack_deadline_seconds = 20
}

# CORS Configuration
resource "google_storage_bucket_cors" "default" {
  count = var.enable_cors ? 1 : 0

  bucket = google_storage_bucket.default.name

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "DELETE", "POST", "PUT"]
    allowed_origins = var.cors_origins
    expose_headers  = ["Content-Length"]
    max_age_seconds = 3600
  }
}

# Bucket Website Configuration (if applicable)
resource "google_storage_bucket_website" "default" {
  count = var.enable_website ? 1 : 0

  bucket = google_storage_bucket.default.name

  main_page_suffix = var.main_page_suffix
  not_found_page   = var.not_found_page
}
