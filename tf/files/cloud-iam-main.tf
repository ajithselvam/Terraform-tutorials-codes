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

# Service Account
resource "google_service_account" "default" {
  account_id   = var.service_account_id
  display_name = var.service_account_display_name
  description  = var.service_account_description
  project      = var.project_id
}

# Service Account Key
resource "google_service_account_key" "default" {
  service_account_id = google_service_account.default.name
  public_key_type    = var.public_key_type
  private_key_type   = var.private_key_type
}

# Additional Service Accounts
resource "google_service_account" "additional_accounts" {
  for_each = var.additional_service_accounts

  account_id   = each.value.account_id
  display_name = each.value.display_name
  description  = each.value.description
  project      = var.project_id
}

# IAM Project-Level Roles
resource "google_project_iam_member" "project_roles" {
  for_each = var.project_iam_roles

  project = var.project_id
  role    = each.value.role
  member  = each.value.member
}

# IAM Service Account Roles
resource "google_service_account_iam_member" "service_account_roles" {
  for_each = var.service_account_iam_roles

  service_account_id = google_service_account.default.name
  role               = each.value.role
  member             = each.value.member
}

# IAM Binding (Multiple Members)
resource "google_project_iam_binding" "project_iam_binding" {
  for_each = var.project_iam_bindings

  project = var.project_id
  role    = each.value.role
  members = each.value.members
}

# Custom IAM Role
resource "google_project_custom_role" "custom_role" {
  for_each = var.custom_roles

  role_id     = each.value.role_id
  title       = each.value.title
  description = each.value.description
  permissions = each.value.permissions
  project     = var.project_id
  stage       = each.value.stage
}

# Service Account Impersonation
resource "google_service_account_iam_member" "impersonate_service_account" {
  service_account_id = google_service_account.default.name
  role               = "roles/iam.serviceAccountUser"
  member             = var.service_account_impersonator
}

# Service Account Impersonation for Token Creation
resource "google_service_account_iam_member" "impersonate_token" {
  service_account_id = google_service_account.default.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = var.token_creator_member
}

# IAM Policy Binding
resource "google_folder_iam_binding" "folder_iam_binding" {
  for_each = var.folder_iam_bindings

  folder  = each.value.folder_id
  role    = each.value.role
  members = each.value.members
}

# Organization-Level IAM
resource "google_organization_iam_binding" "org_iam_binding" {
  for_each = var.organization_iam_bindings

  org_id  = each.value.org_id
  role    = each.value.role
  members = each.value.members
}

# Organization-Level IAM Member
resource "google_organization_iam_member" "org_iam_member" {
  for_each = var.organization_iam_members

  org_id = each.value.org_id
  role   = each.value.role
  member = each.value.member
}

# Service Account Workload Identity Binding
resource "google_service_account_iam_member" "workload_identity" {
  for_each = var.workload_identity_bindings

  service_account_id = google_service_account.default.name
  role               = "roles/iam.workloadIdentityUser"
  member             = each.value
}

# Conditional IAM Binding
resource "google_project_iam_member" "conditional_iam" {
  for_each = var.conditional_iam_roles

  project = var.project_id
  role    = each.value.role
  member  = each.value.member

  condition {
    title       = each.value.condition_title
    description = each.value.condition_description
    expression  = each.value.condition_expression
  }
}

# Service Account Disable/Enable
resource "google_service_account" "disabled_account" {
  for_each = var.disabled_service_accounts

  account_id   = each.value.account_id
  display_name = each.value.display_name
  disabled     = true
  project      = var.project_id
}

# Organization Policy
resource "google_organization_policy" "org_policy" {
  for_each = var.organization_policies

  org_id     = each.value.org_id
  constraint = each.value.constraint

  boolean_policy {
    enforced = each.value.enforced
  }
}

# Folder Organization Policy
resource "google_folder_organization_policy" "folder_policy" {
  for_each = var.folder_organization_policies

  folder_id  = each.value.folder_id
  constraint = each.value.constraint

  list_policy {
    allow {
      all = each.value.allow_all
      values = each.value.allowed_values
    }
    deny {
      values = each.value.denied_values
    }
    suggested_value = each.value.suggested_value
  }
}

# Project Organization Policy
resource "google_project_organization_policy" "project_policy" {
  for_each = var.project_organization_policies

  project_id = var.project_id
  constraint = each.value.constraint

  list_policy {
    allow {
      values = each.value.allowed_values
    }
  }
}

# IAM Audit Logging
resource "google_project_iam_audit_config" "iam_audit" {
  for_each = var.iam_audit_services

  project = var.project_id
  service = each.value.service

  audit_log_config {
    log_type         = each.value.log_type
    exempted_members = each.value.exempted_members
  }
}

# Security Policy for IAM
resource "google_compute_security_policy" "iam_policy" {
  count   = var.enable_security_policy ? 1 : 0
  name    = var.security_policy_name
  project = var.project_id

  rules {
    action   = "allow"
    priority = "0"
    match {
      versioned_expr = "LATEST"
      "match_expr" {
        expression = "true"
      }
    }
    description = "Allow all access"
  }

  rules {
    action   = "deny(403)"
    priority = "1000"
    match {
      versioned_expr = "LATEST"
      "match_expr" {
        expression = "evaluatePreconfiguredExpr('xss-v33')"
      }
    }
    description = "Block XSS attacks"
  }
}

# Workload Identity Pool
resource "google_iam_workload_identity_pool" "workload_pool" {
  count = var.enable_workload_identity_pool ? 1 : 0
  
  workload_identity_pool_id = var.workload_identity_pool_id
  location                  = var.workload_identity_pool_location
  display_name              = var.workload_identity_pool_display_name
  description               = var.workload_identity_pool_description
  project                   = var.project_id
  disabled                  = false
}

# Workload Identity Provider
resource "google_iam_workload_identity_provider" "workload_provider" {
  count = var.enable_workload_identity_pool ? 1 : 0
  
  workload_identity_pool_id          = google_iam_workload_identity_pool.workload_pool[0].workload_identity_pool_id
  workload_identity_provider_id      = var.workload_identity_provider_id
  location                           = var.workload_identity_pool_location
  display_name                       = var.workload_identity_provider_display_name
  attribute_mapping                  = var.attribute_mapping
  issuer_uri                         = var.issuer_uri
  project                            = var.project_id
  attribute_condition                = var.attribute_condition
}

# Service Account Email Output
output "service_account_email" {
  description = "Email of the service account"
  value       = google_service_account.default.email
}

output "service_account_unique_id" {
  description = "Unique ID of the service account"
  value       = google_service_account.default.unique_id
}

output "service_account_key_id" {
  description = "ID of the service account key"
  value       = google_service_account_key.default.id
}

output "custom_role_ids" {
  description = "IDs of custom IAM roles"
  value       = { for k, v in google_project_custom_role.custom_role : k => v.id }
}

output "workload_identity_pool_name" {
  description = "Name of the Workload Identity Pool"
  value       = var.enable_workload_identity_pool ? google_iam_workload_identity_pool.workload_pool[0].name : ""
}
