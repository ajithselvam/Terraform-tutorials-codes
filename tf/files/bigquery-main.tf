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

# BigQuery Dataset
resource "google_bigquery_dataset" "default" {
  dataset_id                  = var.dataset_id
  friendly_name               = var.dataset_name
  description                 = var.dataset_description
  location                    = var.dataset_location
  default_table_expiration_ms = var.default_table_expiration_ms
  project                     = var.project_id

  labels = var.labels

  access {
    role          = "OWNER"
    user_by_email = google_service_account.bigquery_sa.email
  }

  access {
    role          = "READER"
    special_group = "projectReaders"
  }

  access {
    role          = "EDITOR"
    special_group = "projectEditors"
  }

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }
}

# BigQuery Table
resource "google_bigquery_table" "default" {
  for_each = var.tables

  dataset_id = google_bigquery_dataset.default.dataset_id
  table_id   = each.value.table_id
  project    = var.project_id

  description = each.value.description
  labels      = each.value.labels

  schema = jsonencode(each.value.schema)

  time_partitioning {
    type                     = each.value.partition_type
    field                    = each.value.partition_field
    require_partition_filter = each.value.require_partition_filter
  }

  clustering = each.value.clustering_fields

  expiration_time = each.value.expiration_time

  dynamic "table_options" {
    for_each = each.value.external_data != null ? [1] : []
    content {
      external_data_configuration {
        autodetect            = each.value.external_data.autodetect
        source_format         = each.value.external_data.source_format
        source_uris           = each.value.external_data.source_uris
        max_bad_records       = each.value.external_data.max_bad_records
        skip_leading_rows     = each.value.external_data.skip_leading_rows
        allow_quoted_newlines = each.value.external_data.allow_quoted_newlines
      }
    }
  }

  depends_on = [
    google_bigquery_dataset.default
  ]
}

# BigQuery View
resource "google_bigquery_table" "view" {
  for_each = var.views

  dataset_id = google_bigquery_dataset.default.dataset_id
  table_id   = each.value.table_id
  project    = var.project_id

  description = each.value.description

  view {
    query          = each.value.query
    use_legacy_sql = each.value.use_legacy_sql
  }

  depends_on = [
    google_bigquery_dataset.default
  ]
}

# BigQuery Materialized View
resource "google_bigquery_table" "materialized_view" {
  for_each = var.materialized_views

  dataset_id = google_bigquery_dataset.default.dataset_id
  table_id   = each.value.table_id
  project    = var.project_id

  description = each.value.description

  materialized_view {
    query = each.value.query
  }

  depends_on = [
    google_bigquery_dataset.default
  ]
}

# BigQuery Connection
resource "google_bigquery_connection" "connection" {
  for_each = var.connections

  connection_id       = each.value.connection_id
  location            = each.value.location
  friendly_name       = each.value.friendly_name
  description         = each.value.description
  project             = var.project_id

  dynamic "cloud_resource" {
    for_each = each.value.connection_type == "CLOUD_RESOURCE" ? [1] : []
    content {}
  }

  dynamic "aws" {
    for_each = each.value.connection_type == "AWS" ? [1] : []
    content {
      authentication_type = each.value.aws_auth_type
      role_arn           = each.value.aws_role_arn
    }
  }
}

# BigQuery Scheduled Query (for data refreshes)
resource "google_bigquery_data_transfer_config" "scheduled_query" {
  for_each = var.scheduled_queries

  location       = var.dataset_location
  display_name   = each.value.display_name
  data_source_id = "scheduled_query"
  destination_dataset_id = google_bigquery_dataset.default.dataset_id
  schedule       = each.value.schedule
  params = {
    destination_table_name_template = each.value.destination_table
    write_disposition               = "WRITE_TRUNCATE"
    partitioning_field              = each.value.partitioning_field
    query                          = each.value.query
  }

  service_account_name = google_service_account.bigquery_sa.email
  project_id          = var.project_id
}

# BigQuery Reservation
resource "google_bigquery_reservation" "reservation" {
  count             = var.enable_reservation ? 1 : 0
  name              = var.reservation_name
  location          = var.reservation_location
  slot_capacity     = var.slot_capacity
  edition           = var.reservation_edition
  project           = var.project_id
  ignore_idle_slots = var.ignore_idle_slots
}

# BigQuery Reservation Assignment
resource "google_bigquery_reservation_assignment" "assignment" {
  count             = var.enable_reservation ? 1 : 0
  assignee          = "projects/${var.project_id}"
  job_type          = "QUERY"
  reservation       = google_bigquery_reservation.reservation[0].id
  project_id        = var.project_id
  location          = var.reservation_location
}

# BigQuery Dataset IAM
resource "google_bigquery_dataset_iam_member" "reader" {
  for_each = toset(var.dataset_readers)

  dataset_id = google_bigquery_dataset.default.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = each.value
  project    = var.project_id
}

resource "google_bigquery_dataset_iam_member" "editor" {
  for_each = toset(var.dataset_editors)

  dataset_id = google_bigquery_dataset.default.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = each.value
  project    = var.project_id
}

# Service Account for BigQuery
resource "google_service_account" "bigquery_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for BigQuery"
}

# IAM Binding for Service Account
resource "google_project_iam_member" "bigquery_user" {
  project = var.project_id
  role    = "roles/bigquery.user"
  member  = "serviceAccount:${google_service_account.bigquery_sa.email}"
}

resource "google_project_iam_member" "bigquery_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.bigquery_sa.email}"
}

# BigQuery Log Sink
resource "google_logging_project_sink" "bigquery_sink" {
  count           = var.enable_logging_sink ? 1 : 0
  name            = "${var.dataset_id}-sink"
  destination     = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.default.dataset_id}"
  filter          = var.sink_filter
  unique_writer_identity = true
  project         = var.project_id
}

# Grant BigQuery sink write permissions
resource "google_bigquery_dataset_iam_member" "sink_writer" {
  count      = var.enable_logging_sink ? 1 : 0
  dataset_id = google_bigquery_dataset.default.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.bigquery_sink[0].writer_identity
  project    = var.project_id
}

output "dataset_id" {
  description = "ID of the BigQuery dataset"
  value       = google_bigquery_dataset.default.dataset_id
}

output "dataset_project" {
  description = "Project of the BigQuery dataset"
  value       = google_bigquery_dataset.default.project
}

output "bigquery_service_account_email" {
  description = "Email of the BigQuery service account"
  value       = google_service_account.bigquery_sa.email
}
