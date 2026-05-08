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

# Pub/Sub Topic
resource "google_pubsub_topic" "default" {
  name                       = var.topic_name
  project                    = var.project_id
  message_retention_duration = var.message_retention_duration
  message_storage_policy {
    allowed_persistence_regions = var.persistence_regions
  }

  kms_key_name = var.kms_key_name

  labels = var.labels
}

# Pub/Sub Subscription
resource "google_pubsub_subscription" "default" {
  name                 = var.subscription_name
  topic                = google_pubsub_topic.default.name
  project              = var.project_id
  ack_deadline_seconds = var.ack_deadline_seconds

  message_retention_duration = var.subscription_message_retention

  retain_acked_messages = var.retain_acked_messages

  dead_letter_policy {
    dead_letter_topic            = google_pubsub_topic.dead_letter[0].id
    max_delivery_attempts        = var.max_delivery_attempts
  }

  push_config {
    push_endpoint = var.push_endpoint
    oidc_token_audience = var.oidc_token_audience

    attributes = {
      x-goog-version = "v1"
    }
  }

  enable_message_ordering = var.enable_message_ordering
}

# Dead Letter Topic
resource "google_pubsub_topic" "dead_letter" {
  count   = var.enable_dead_letter_policy ? 1 : 0
  name    = "${var.topic_name}-dead-letter"
  project = var.project_id
}

# Dead Letter Subscription
resource "google_pubsub_subscription" "dead_letter" {
  count   = var.enable_dead_letter_policy ? 1 : 0
  name    = "${var.subscription_name}-dead-letter"
  topic   = google_pubsub_topic.dead_letter[0].name
  project = var.project_id
  ack_deadline_seconds = 60
}

# Pub/Sub Topic IAM Binding - Publisher
resource "google_pubsub_topic_iam_member" "publisher" {
  for_each = toset(var.publisher_members)

  topic  = google_pubsub_topic.default.name
  role   = "roles/pubsub.publisher"
  member = each.value
}

# Pub/Sub Topic IAM Binding - Subscriber
resource "google_pubsub_topic_iam_member" "subscriber" {
  for_each = toset(var.subscriber_members)

  topic  = google_pubsub_topic.default.name
  role   = "roles/pubsub.subscriber"
  member = each.value
}

# Pub/Sub Subscription IAM Binding
resource "google_pubsub_subscription_iam_member" "subscriber" {
  for_each = toset(var.subscription_members)

  subscription = google_pubsub_subscription.default.name
  role         = "roles/pubsub.subscriber"
  member       = each.value
}

# Pull Subscription (for Cloud Functions or App Engine)
resource "google_pubsub_subscription" "pull_subscription" {
  count   = var.enable_pull_subscription ? 1 : 0
  name    = "${var.subscription_name}-pull"
  topic   = google_pubsub_topic.default.name
  project = var.project_id
  ack_deadline_seconds = var.ack_deadline_seconds
}

# Service Account for Pub/Sub
resource "google_service_account" "pubsub_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for Pub/Sub"
}

# IAM Binding for Pub/Sub Service Account
resource "google_pubsub_topic_iam_member" "pubsub_publisher" {
  topic  = google_pubsub_topic.default.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.pubsub_sa.email}"
}

resource "google_pubsub_subscription_iam_member" "pubsub_subscriber" {
  subscription = google_pubsub_subscription.default.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.pubsub_sa.email}"
}

# Pub/Sub Snapshot (for subscription state)
resource "google_pubsub_subscription_snapshot" "default" {
  count        = var.enable_snapshot ? 1 : 0
  name         = "${var.subscription_name}-snapshot"
  subscription = google_pubsub_subscription.default.name
  project      = var.project_id
}

# Export Topic Schema
resource "google_pubsub_schema" "default" {
  count      = var.enable_schema ? 1 : 0
  name       = "${var.topic_name}-schema"
  project    = var.project_id
  type       = var.schema_type
  definition = var.schema_definition
}

# Attach Schema to Topic
resource "google_pubsub_topic_schema" "default" {
  count   = var.enable_schema ? 1 : 0
  topic   = google_pubsub_topic.default.name
  schema  = google_pubsub_schema.default[0].id
  encoding = var.schema_encoding
}

# Monitoring Alert for Topic
resource "google_monitoring_alert_policy" "pubsub_alert" {
  count        = var.enable_monitoring_alert ? 1 : 0
  display_name = "${var.topic_name}-alert"
  combiner     = "OR"
  project      = var.project_id

  conditions {
    display_name = "High latency on ${var.topic_name}"

    condition_threshold {
      filter          = "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\" AND resource.labels.subscription_id=\"${google_pubsub_subscription.default.name}\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.latency_threshold
    }
  }

  notification_channels = var.notification_channels
}

output "topic_name" {
  description = "Name of the Pub/Sub Topic"
  value       = google_pubsub_topic.default.name
}

output "subscription_name" {
  description = "Name of the Pub/Sub Subscription"
  value       = google_pubsub_subscription.default.name
}

output "pubsub_service_account_email" {
  description = "Email of the Pub/Sub service account"
  value       = google_service_account.pubsub_sa.email
}
