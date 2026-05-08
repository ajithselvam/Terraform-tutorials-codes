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

# Cloud Armor Security Policy
resource "google_compute_security_policy" "default" {
  name        = var.policy_name
  description = var.policy_description
  project     = var.project_id

  # Default rule - allow all traffic
  rules {
    action   = "allow"
    priority = "65535"
    match {
      versioned_expr = "LATEST"
      version_expr {
        expression = "true"
      }
    }
    description = "Default rule"
  }

  # Block XSS attacks
  rules {
    action   = "deny(403)"
    priority = "1000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33')"
      }
    }
    description = "Block XSS attacks"
    preview     = var.preview_mode
  }

  # Block SQL Injection
  rules {
    action   = "deny(403)"
    priority = "1001"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33')"
      }
    }
    description = "Block SQL Injection attacks"
    preview     = var.preview_mode
  }

  # Block Local File Inclusion (LFI)
  rules {
    action   = "deny(403)"
    priority = "1002"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('lfi-v33')"
      }
    }
    description = "Block Local File Inclusion attacks"
    preview     = var.preview_mode
  }

  # Block Remote Code Execution (RCE)
  rules {
    action   = "deny(403)"
    priority = "1003"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('rce-v33')"
      }
    }
    description = "Block Remote Code Execution attacks"
    preview     = var.preview_mode
  }

  # Block Protocol Attacks
  rules {
    action   = "deny(403)"
    priority = "1004"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('protocolattack-v33')"
      }
    }
    description = "Block Protocol attacks"
    preview     = var.preview_mode
  }

  # Block Scanner Detection
  rules {
    action   = "deny(403)"
    priority = "1005"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('scannerdetection-v33')"
      }
    }
    description = "Block Scanner Detection"
    preview     = var.preview_mode
  }

  # Custom Rule - Rate Limiting
  rules {
    action   = "rate_based_ban"
    priority = "2000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "true"
      }
    }
    description = "Rate limiting rule"
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"

      rate_limit_threshold {
        count        = var.rate_limit_count
        interval_sec = var.rate_limit_interval_sec
      }

      ban_duration_sec = var.ban_duration_sec

      enforce_on_key = var.enforce_on_key

      enforce_on_key_configs {
        enforce_on_key_type = var.enforce_on_key_type
      }
    }
    preview = var.preview_mode
  }

  # Block Specific IPs
  rules {
    action   = "deny(403)"
    priority = "3000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "origin.region_code == 'CN' || origin.region_code == 'RU'"
      }
    }
    description = "Block traffic from specific regions"
    preview     = var.preview_mode
  }

  # Allow specific IPs (Whitelist)
  rules {
    action   = "allow"
    priority = "100"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "inIpRange(origin.ip, var.whitelist_ips)"
      }
    }
    description = "Allow whitelisted IPs"
  }

  # Custom Header-based rule
  rules {
    action   = "deny(403)"
    priority = "4000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "has(request.headers['X-API-Key']) && request.headers['X-API-Key'] != 'valid-key'"
      }
    }
    description = "Block requests with invalid API key"
    preview     = var.preview_mode
  }

  # Block requests without User-Agent
  rules {
    action   = "deny(403)"
    priority = "4001"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "!has(request.headers['User-Agent'])"
      }
    }
    description = "Block requests without User-Agent header"
    preview     = var.preview_mode
  }

  # Block Large Requests
  rules {
    action   = "deny(413)"
    priority = "5000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "int(request.headers['content-length']) > ${var.max_content_length}"
      }
    }
    description = "Block requests larger than size limit"
    preview     = var.preview_mode
  }

  # Adaptive DDoS Protection
  rules {
    action   = "deny(503)"
    priority = "6000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('json-sqli-v33')"
      }
    }
    description = "Block JSON SQL Injection"
    preview     = var.preview_mode
  }

  labels = var.labels
}

# Adaptive Protection Config
resource "google_compute_security_policy_adaptive_protection_config" "adaptive_protection" {
  count          = var.enable_adaptive_protection ? 1 : 0
  security_policy = google_compute_security_policy.default.name
  project         = var.project_id

  auto_deploy_config {
    auto_deploy_enabled   = true
    confidence_threshold  = var.confidence_threshold
  }

  layer_7_ddos_defense_config {
    enable          = true
    rule_visibility = var.rule_visibility
  }
}

# Additional Security Policy for WAF Rules
resource "google_compute_security_policy" "waf_policy" {
  count       = var.enable_waf_policy ? 1 : 0
  name        = "${var.policy_name}-waf"
  description = "Web Application Firewall Policy"
  project     = var.project_id

  rules {
    action   = "allow"
    priority = "65535"
    match {
      versioned_expr = "LATEST"
      version_expr {
        expression = "true"
      }
    }
    description = "Default rule"
  }

  # Preconfigured WAF Rules
  rules {
    action   = "deny(403)"
    priority = "1000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33', ['owasp-crs-v030001-id941110-xss'])"
      }
    }
    description = "Block reflected XSS"
    preview     = var.preview_mode
  }

  rules {
    action   = "deny(403)"
    priority = "1001"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33', ['owasp-crs-v030001-id942251-sqli'])"
      }
    }
    description = "Block SQL Injection in POST body"
    preview     = var.preview_mode
  }

  rules {
    action   = "deny(403)"
    priority = "1002"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('protocolattack-v33', ['owasp-crs-v030001-id921110-http'])"
      }
    }
    description = "Block HTTP protocol attacks"
    preview     = var.preview_mode
  }
}

# Geo-blocking Security Policy
resource "google_compute_security_policy" "geo_blocking_policy" {
  count       = var.enable_geo_blocking ? 1 : 0
  name        = "${var.policy_name}-geo-blocking"
  description = "Geo-blocking Policy"
  project     = var.project_id

  rules {
    action   = "allow"
    priority = "65535"
    match {
      versioned_expr = "LATEST"
      version_expr {
        expression = "true"
      }
    }
    description = "Default rule"
  }

  # Block traffic from blocked regions
  rules {
    action   = "deny(403)"
    priority = "1000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "origin.region_code in ['${join("', '", var.blocked_regions)}']"
      }
    }
    description = "Block traffic from blocked regions"
    preview     = var.preview_mode
  }

  # Allow only traffic from allowed regions
  rules {
    action   = "allow"
    priority = "100"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "origin.region_code in ['${join("', '", var.allowed_regions)}']"
      }
    }
    description = "Allow traffic from allowed regions"
  }
}

# Bot Management Policy
resource "google_compute_security_policy" "bot_management_policy" {
  count       = var.enable_bot_management ? 1 : 0
  name        = "${var.policy_name}-bot-management"
  description = "Bot Management Policy"
  project     = var.project_id

  rules {
    action   = "allow"
    priority = "65535"
    match {
      versioned_expr = "LATEST"
      version_expr {
        expression = "true"
      }
    }
    description = "Default rule"
  }

  # Block known bot traffic
  rules {
    action   = "deny(403)"
    priority = "1000"
    match {
      versioned_expr = "LATEST"
      expr {
        expression = "evaluatePreconfiguredExpr('botmanagement-v1')"
      }
    }
    description = "Block known bots"
    preview     = var.preview_mode
  }
}

# Attach Security Policy to Backend Service
resource "google_compute_backend_service_security_policy" "backend_policy" {
  name            = var.backend_service_name
  security_policy = google_compute_security_policy.default.id
  project         = var.project_id
}

# Log Configuration for Security Policy
resource "google_compute_security_policy_rule" "logging_rule" {
  count           = var.enable_logging ? 1 : 0
  security_policy = google_compute_security_policy.default.name
  action          = "allow"
  priority        = "65534"
  description     = "Logging rule"
  match {
    versioned_expr = "LATEST"
    version_expr {
      expression = "true"
    }
  }
  header_action {
    request_headers_to_add {
      header_name  = "X-Cloud-Armor-Log"
      header_value = "true"
    }
  }
}

# Monitoring Alert for Security Policy
resource "google_monitoring_alert_policy" "security_policy_alert" {
  count        = var.enable_monitoring_alert ? 1 : 0
  display_name = "${var.policy_name}-alert"
  combiner     = "OR"
  project      = var.project_id

  conditions {
    display_name = "High blocked request rate"

    condition_threshold {
      filter          = "metric.type=\"compute.googleapis.com/security_policy/request_count\" AND resource.labels.policy_name=\"${google_compute_security_policy.default.name}\" AND metric.labels.policy_rule_action=\"deny\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.alert_threshold
    }
  }

  notification_channels = var.notification_channels
}

# Logging Sink for Security Policy Events
resource "google_logging_project_sink" "security_policy_sink" {
  count           = var.enable_security_logging_sink ? 1 : 0
  name            = "${var.policy_name}-logs"
  destination     = "storage.googleapis.com/${google_storage_bucket.security_logs[0].name}"
  filter          = "protoPayload.serviceName=\"compute.googleapis.com\" AND protoPayload.methodName:\"compute.SecurityPolicies\""
  unique_writer_identity = true
  project         = var.project_id
}

# Storage bucket for security logs
resource "google_storage_bucket" "security_logs" {
  count    = var.enable_security_logging_sink ? 1 : 0
  name     = "${var.project_id}-security-logs-${data.google_client_config.default.project}"
  location = var.region
  project  = var.project_id

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = var.log_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

# IAM binding for security log sink
resource "google_storage_bucket_iam_member" "security_logs_writer" {
  count  = var.enable_security_logging_sink ? 1 : 0
  bucket = google_storage_bucket.security_logs[0].name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.security_policy_sink[0].writer_identity
  project = var.project_id
}

# Data source for current GCP config
data "google_client_config" "default" {}

output "security_policy_name" {
  description = "Name of the Cloud Armor Security Policy"
  value       = google_compute_security_policy.default.name
}

output "security_policy_id" {
  description = "ID of the Cloud Armor Security Policy"
  value       = google_compute_security_policy.default.id
}

output "security_policy_fingerprint" {
  description = "Fingerprint of the security policy"
  value       = google_compute_security_policy.default.fingerprint
}

output "waf_policy_name" {
  description = "Name of the WAF Security Policy"
  value       = var.enable_waf_policy ? google_compute_security_policy.waf_policy[0].name : ""
}

output "geo_blocking_policy_name" {
  description = "Name of the Geo-blocking Policy"
  value       = var.enable_geo_blocking ? google_compute_security_policy.geo_blocking_policy[0].name : ""
}

output "bot_management_policy_name" {
  description = "Name of the Bot Management Policy"
  value       = var.enable_bot_management ? google_compute_security_policy.bot_management_policy[0].name : ""
}
