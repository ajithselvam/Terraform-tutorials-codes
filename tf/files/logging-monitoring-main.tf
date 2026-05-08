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

# Logging Sink - Cloud Storage
resource "google_logging_project_sink" "storage_sink" {
  name            = var.storage_sink_name
  destination     = "storage.googleapis.com/${google_storage_bucket.logging_bucket.name}"
  filter          = var.logging_filter
  unique_writer_identity = true
  project         = var.project_id
}

# Storage Bucket for Logs
resource "google_storage_bucket" "logging_bucket" {
  name          = "${var.project_id}-logs-${data.google_client_config.default.project}"
  location      = var.region
  storage_class = var.storage_class
  project       = var.project_id

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = var.log_retention_days
    }
    action {
      type = "Delete"
    }
  }

  versioning {
    enabled = var.enable_versioning
  }
}

# Grant storage sink write permissions
resource "google_storage_bucket_iam_member" "logging_sink_writer" {
  bucket = google_storage_bucket.logging_bucket.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.storage_sink.writer_identity
  project = var.project_id
}

# Logging Sink - BigQuery
resource "google_logging_project_sink" "bigquery_sink" {
  count           = var.enable_bigquery_sink ? 1 : 0
  name            = var.bigquery_sink_name
  destination     = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logging_dataset[0].dataset_id}"
  filter          = var.logging_filter
  unique_writer_identity = true
  project         = var.project_id
}

# BigQuery Dataset for Logs
resource "google_bigquery_dataset" "logging_dataset" {
  count       = var.enable_bigquery_sink ? 1 : 0
  dataset_id  = var.bigquery_dataset_id
  location    = var.region
  description = "Dataset for logging sink"
  project     = var.project_id

  default_table_expiration_ms = var.bigquery_table_expiration_ms

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }

  access {
    role          = "EDITOR"
    special_group = "projectEditors"
  }

  access {
    role          = "READER"
    special_group = "projectReaders"
  }
}

# Grant BigQuery sink write permissions
resource "google_bigquery_dataset_iam_member" "logging_sink_writer" {
  count      = var.enable_bigquery_sink ? 1 : 0
  dataset_id = google_bigquery_dataset.logging_dataset[0].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.bigquery_sink[0].writer_identity
  project    = var.project_id
}

# Logging Sink - Pub/Sub
resource "google_logging_project_sink" "pubsub_sink" {
  count       = var.enable_pubsub_sink ? 1 : 0
  name        = var.pubsub_sink_name
  destination = "pubsub.googleapis.com/projects/${var.project_id}/topics/${google_pubsub_topic.logging_topic[0].name}"
  filter      = var.logging_filter
  project     = var.project_id
}

# Pub/Sub Topic for Logs
resource "google_pubsub_topic" "logging_topic" {
  count   = var.enable_pubsub_sink ? 1 : 0
  name    = var.pubsub_topic_name
  project = var.project_id
}

# Grant Pub/Sub sink publish permissions
resource "google_pubsub_topic_iam_member" "logging_sink_publisher" {
  count  = var.enable_pubsub_sink ? 1 : 0
  topic  = google_pubsub_topic.logging_topic[0].name
  role   = "roles/pubsub.publisher"
  member = google_logging_project_sink.pubsub_sink[0].writer_identity
}

# Log View
resource "google_logging_project_bucket_config" "log_view" {
  project_id   = var.project_id
  location     = "global"
  bucket_id    = "_Default"
  retention_days = var.log_retention_days

  enable_analytics = var.enable_log_analytics
}

# Metric from Log
resource "google_logging_metric" "custom_metric" {
  for_each = var.custom_metrics

  name   = each.value.name
  filter = each.value.filter
  project = var.project_id

  metric_descriptor {
    metric_kind = each.value.metric_kind
    value_type  = each.value.value_type
    labels {
      key         = "method"
      value_type  = "STRING"
      description = "Request method"
    }
    labels {
      key         = "status"
      value_type  = "STRING"
      description = "Response status"
    }
  }

  value_extractor = each.value.value_extractor
  label_extractors = each.value.label_extractors
}

# Uptime Check
resource "google_monitoring_uptime_check_config" "http" {
  for_each = var.uptime_checks

  display_name = each.value.display_name
  http_check {
    path           = each.value.path
    port           = each.value.port
    request_method = each.value.request_method
  }
  monitored_resource {
    type = "uptime-url"
    labels = {
      host = each.value.host
    }
  }
  selected_regions = each.value.selected_regions
  period           = each.value.period
  timeout          = each.value.timeout
  project          = var.project_id
}

# Alert Policy
resource "google_monitoring_alert_policy" "alert_policy" {
  for_each = var.alert_policies

  display_name = each.value.display_name
  combiner     = each.value.combiner
  project      = var.project_id

  conditions {
    display_name = each.value.condition_display_name

    condition_threshold {
      filter          = each.value.filter
      duration        = "${each.value.duration_seconds}s"
      comparison      = each.value.comparison
      threshold_value = each.value.threshold_value

      aggregations {
        alignment_period   = "${each.value.alignment_period_seconds}s"
        per_series_aligner = each.value.per_series_aligner
      }
    }
  }

  notification_channels = each.value.notification_channels
  documentation {
    content   = each.value.documentation_content
    mime_type = "text/markdown"
  }
}

# Notification Channel - Email
resource "google_monitoring_notification_channel" "email" {
  for_each = var.email_notification_channels

  display_name = each.value.display_name
  type         = "email"
  enabled      = each.value.enabled
  labels = {
    email_address = each.value.email
  }
  project = var.project_id
}

# Notification Channel - Slack
resource "google_monitoring_notification_channel" "slack" {
  for_each = var.slack_notification_channels

  display_name = each.value.display_name
  type         = "slack"
  enabled      = each.value.enabled
  labels = {
    channel_name = each.value.channel_name
  }
  sensitive_labels {
    auth_token = each.value.auth_token
  }
  project = var.project_id
}

# Notification Channel - PagerDuty
resource "google_monitoring_notification_channel" "pagerduty" {
  for_each = var.pagerduty_notification_channels

  display_name = each.value.display_name
  type         = "pagerduty"
  enabled      = each.value.enabled
  sensitive_labels {
    service_key = each.value.service_key
  }
  project = var.project_id
}

# Service Level Indicator (SLI)
resource "google_monitoring_service_level_indicator" "sli" {
  for_each = var.service_level_indicators

  project_id   = var.project_id
  display_name = each.value.display_name

  windows_based_sli {
    window_duration = "${each.value.window_duration_seconds}s"

    good_bad_metric_filter = each.value.good_bad_metric_filter
  }
}

# Service Level Objective (SLO)
resource "google_monitoring_slo" "slo" {
  for_each = var.service_level_objectives

  project_id   = var.project_id
  display_name = each.value.display_name
  service_level_indicator_id = each.value.sli_id
  goal         = each.value.goal
  rolling_period_days = each.value.rolling_period_days
}

# Dashboard
resource "google_monitoring_dashboard" "dashboard" {
  for_each = var.dashboards

  project_id = var.project_id
  dashboard_json = templatefile(
    "${path.module}/${each.value.dashboard_json_file}",
    each.value.template_variables
  )
}

# Log Router Settings
resource "google_logging_project_bucket_config" "advanced_bucket" {
  count        = var.enable_advanced_logging ? 1 : 0
  project_id   = var.project_id
  location     = var.region
  bucket_id    = var.advanced_bucket_id
  retention_days = var.advanced_bucket_retention

  enable_analytics = true
}

# Data source for current GCP config
data "google_client_config" "default" {}

output "logging_bucket_name" {
  description = "Name of the logging bucket"
  value       = google_storage_bucket.logging_bucket.name
}

output "logging_sink_name" {
  description = "Name of the logging sink"
  value       = google_logging_project_sink.storage_sink.name
}

output "notification_channel_emails" {
  description = "Notification channels for email"
  value       = { for k, v in google_monitoring_notification_channel.email : k => v.id }
}

output "alert_policy_ids" {
  description = "IDs of the alert policies"
  value       = { for k, v in google_monitoring_alert_policy.alert_policy : k => v.id }
}
