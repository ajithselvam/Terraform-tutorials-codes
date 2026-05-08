terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "archive" {}

# Archive function source code
data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = var.function_source_dir
  output_path = var.function_zip_path
}

# Cloud Storage Bucket for function source
resource "google_storage_bucket" "function_bucket" {
  name          = "${var.project_id}-cloud-functions-${data.google_client_config.default.project}"
  location      = var.region
  storage_class = "STANDARD"
  project       = var.project_id

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

# Upload function source to Cloud Storage
resource "google_storage_bucket_object" "function_zip" {
  name   = "function-${data.archive_file.function_zip.output_base64sha256}.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = data.archive_file.function_zip.output_path
}

# Cloud Function (2nd Generation)
resource "google_cloudfunctions2_function" "function" {
  name        = var.function_name
  location    = var.region
  description = var.function_description
  project     = var.project_id

  build_config {
    runtime     = var.runtime
    entry_point = var.entry_point
    source {
      storage {
        bucket = google_storage_bucket.function_bucket.name
        object = google_storage_bucket_object.function_zip.name
      }
    }

    environment_variables = merge(
      var.build_environment_variables,
      {
        ENVIRONMENT = var.environment
      }
    )
  }

  service_config {
    max_instance_count             = var.max_instances
    min_instance_count             = var.min_instances
    available_memory_mb            = var.memory_mb
    timeout_seconds                = var.timeout_seconds
    environment_variables          = var.environment_variables
    ingress_settings               = var.ingress_settings
    all_traffic_on_latest_revision = true
    service_account_email          = google_service_account.function_sa.email
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = var.event_type
    pubsub_topic          = var.pubsub_trigger_topic
    event_filters {
      attribute = "bucket"
      value     = var.storage_trigger_bucket
    }
    retry_policy = var.enable_retry_policy ? "RETRY_POLICY_RETRY" : "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.function_sa.email
  }

  depends_on = [
    google_storage_bucket_object.function_zip
  ]
}

# Cloud Function IAM - Allow public invocation
resource "google_cloudfunctions2_function_iam_member" "public_invoker" {
  count      = var.allow_public_invocation ? 1 : 0
  cloud_function = google_cloudfunctions2_function.function.name
  role   = "roles/cloudfunctions.invoker"
  member = "allUsers"
  location = var.region
}

# Cloud Function IAM - Specific service accounts
resource "google_cloudfunctions2_function_iam_member" "invoker" {
  for_each = toset(var.invoker_members)

  cloud_function = google_cloudfunctions2_function.function.name
  role   = "roles/cloudfunctions.invoker"
  member = each.value
  location = var.region
}

# Service Account for Cloud Function
resource "google_service_account" "function_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for Cloud Functions"
}

# IAM Bindings for Service Account
resource "google_project_iam_member" "function_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_project_iam_member" "function_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

# Cloud Function for HTTP Trigger
resource "google_cloudfunctions2_function" "http_function" {
  count       = var.enable_http_trigger ? 1 : 0
  name        = "${var.function_name}-http"
  location    = var.region
  description = "HTTP triggered Cloud Function"
  project     = var.project_id

  build_config {
    runtime     = var.runtime
    entry_point = var.entry_point
    source {
      storage {
        bucket = google_storage_bucket.function_bucket.name
        object = google_storage_bucket_object.function_zip.name
      }
    }
  }

  service_config {
    max_instance_count             = var.max_instances
    min_instance_count             = var.min_instances
    available_memory_mb            = var.memory_mb
    timeout_seconds                = var.timeout_seconds
    ingress_settings               = var.ingress_settings
    all_traffic_on_latest_revision = true
    service_account_email          = google_service_account.function_sa.email
  }
}

# Cloud Function IAM for HTTP Function
resource "google_cloudfunctions2_function_iam_member" "http_public_invoker" {
  count      = var.enable_http_trigger && var.allow_public_invocation ? 1 : 0
  cloud_function = google_cloudfunctions2_function.http_function[0].name
  role   = "roles/cloudfunctions.invoker"
  member = "allUsers"
  location = var.region
}

# Cloud Scheduler Job to trigger Cloud Function
resource "google_cloud_scheduler_job" "function_trigger" {
  count           = var.enable_scheduler ? 1 : 0
  name            = "${var.function_name}-schedule"
  region          = var.region
  schedule        = var.schedule_cron
  time_zone       = var.time_zone
  attempt_deadline = "${var.timeout_seconds}s"
  project         = var.project_id

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.http_function[0].service_config[0].uri
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(var.scheduler_payload)
    oidc_token {
      service_account_email = google_service_account.function_sa.email
    }
  }
}

# Monitoring Alert for Cloud Function
resource "google_monitoring_alert_policy" "function_alert" {
  count        = var.enable_monitoring_alert ? 1 : 0
  display_name = "${var.function_name}-alert"
  combiner     = "OR"
  project      = var.project_id

  conditions {
    display_name = "High error rate on ${var.function_name}"

    condition_threshold {
      filter          = "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" AND resource.labels.function_name=\"${google_cloudfunctions2_function.function.name}\" AND metric.labels.status=\"error\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.error_rate_threshold
    }
  }

  notification_channels = var.notification_channels
}

# Data source for current GCP config
data "google_client_config" "default" {}

output "function_name" {
  description = "Name of the Cloud Function"
  value       = google_cloudfunctions2_function.function.name
}

output "function_uri" {
  description = "URI of the Cloud Function (for HTTP trigger)"
  value       = var.enable_http_trigger ? google_cloudfunctions2_function.http_function[0].service_config[0].uri : ""
}

output "service_account_email" {
  description = "Email of the function service account"
  value       = google_service_account.function_sa.email
}
