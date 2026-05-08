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

# Cloud Run Service
resource "google_cloud_run_service" "default" {
  name     = var.service_name
  location = var.region

  template {
    spec {
      service_account_name = google_service_account.cloud_run_sa.email

      containers {
        image = var.container_image

        ports {
          container_port = var.container_port
        }

        env {
          name  = "LOG_LEVEL"
          value = var.log_level
        }

        env {
          name  = "ENVIRONMENT"
          value = var.environment
        }

        resources {
          limits = {
            cpu    = var.cpu_limit
            memory = var.memory_limit
          }
        }
      }

      timeout_seconds = var.timeout_seconds
      max_instances   = var.max_instances
    }

    metadata {
      annotations = {
        "autoscaling.knative.dev/min-scale" = var.min_instances
        "autoscaling.knative.dev/max-scale" = var.max_instances
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  depends_on = [
    google_project_iam_member.cloud_run_log_writer
  ]
}

# Cloud Run Service IAM - Public Access
resource "google_cloud_run_service_iam_member" "public_access" {
  count   = var.allow_public_access ? 1 : 0
  service = google_cloud_run_service.default.name
  role    = "roles/run.invoker"
  member  = "allUsers"
  location = var.region
}

# Cloud Run Service IAM - Specific Users/Service Accounts
resource "google_cloud_run_service_iam_member" "invoker" {
  for_each = toset(var.invoker_members)

  service  = google_cloud_run_service.default.name
  role     = "roles/run.invoker"
  member   = each.value
  location = var.region
}

# Service Account for Cloud Run
resource "google_service_account" "cloud_run_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for Cloud Run"
}

# IAM Bindings for Service Account
resource "google_project_iam_member" "cloud_run_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_project_iam_member" "cloud_run_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Cloud Run Domain Mapping
resource "google_cloud_run_domain_mapping" "default" {
  count       = var.domain_name != "" ? 1 : 0
  location    = var.region
  name        = var.domain_name
  service_name = google_cloud_run_service.default.name

  metadata {
    namespace = var.project_id
  }
}

# Cloud Run Service Autoscaling (via metadata)
# Note: Min and max instances are set in the metadata section above

# Logging for Cloud Run
resource "google_logging_project_sink" "cloud_run_sink" {
  count           = var.enable_logging ? 1 : 0
  name            = "${var.service_name}-logs"
  destination     = "storage.googleapis.com/${google_storage_bucket.logs[0].name}"
  filter          = "resource.type=\"cloud_run_instance\" AND resource.labels.service_name=\"${google_cloud_run_service.default.name}\""
  unique_writer_identity = true
}

# Storage bucket for logs
resource "google_storage_bucket" "logs" {
  count    = var.enable_logging ? 1 : 0
  name     = "${var.project_id}-cloud-run-logs-${data.google_client_config.default.project}"
  location = var.region

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

# IAM binding for log sink
resource "google_storage_bucket_iam_member" "logs_writer" {
  count  = var.enable_logging ? 1 : 0
  bucket = google_storage_bucket.logs[0].name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.cloud_run_sink[0].writer_identity
}

# Data source for current GCP config
data "google_client_config" "default" {}

# Cloud Run Revision settings
resource "google_cloud_run_v2_service" "v2_default" {
  count    = var.use_cloud_run_v2 ? 1 : 0
  name     = "${var.service_name}-v2"
  location = var.region

  template {
    service_account = google_service_account.cloud_run_sa.email

    containers {
      image = var.container_image

      ports {
        container_port = var.container_port
      }

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      resources {
        limits = {
          cpu    = var.cpu_limit
          memory = var.memory_limit
        }
      }
    }

    max_instance_request_concurrency = var.concurrency_limit
    timeout = "${var.timeout_seconds}s"
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}
