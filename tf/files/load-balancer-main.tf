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

# Health Check
resource "google_compute_health_check" "default" {
  name        = var.health_check_name
  description = "Health check for backend servers"
  project     = var.project_id

  http_health_check {
    port               = var.health_check_port
    request_path       = var.health_check_path
    check_interval_sec = var.health_check_interval
    timeout_sec        = var.health_check_timeout
    healthy_threshold  = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
  }
}

# Backend Service
resource "google_compute_backend_service" "default" {
  name                    = var.backend_service_name
  project                 = var.project_id
  protocol                = var.protocol
  port_name               = var.port_name
  timeout_sec             = var.timeout_sec
  health_checks           = [google_compute_health_check.default.id]
  load_balancing_scheme   = var.load_balancing_scheme
  enable_cdn              = var.enable_cdn
  custom_request_headers  = var.custom_request_headers
  custom_response_headers = var.custom_response_headers

  session_affinity = var.session_affinity

  cdn_policy {
    cache_mode       = var.cache_mode
    default_ttl      = var.default_ttl
    max_ttl          = var.max_ttl
    client_ttl       = var.client_ttl
    cache_key_policy {
      include_host           = true
      include_protocol       = true
      include_query_string   = var.include_query_string
      query_string_whitelist = var.query_string_whitelist
    }
  }

  log_config {
    enable      = var.enable_logging
    sample_rate = var.log_sample_rate
  }

  dynamic "backend" {
    for_each = var.backends
    content {
      group                        = backend.value.group
      balancing_mode               = backend.value.balancing_mode
      max_rate_per_instance        = backend.value.max_rate_per_instance
      capacity_scaler              = backend.value.capacity_scaler
    }
  }

  depends_on = [
    google_compute_health_check.default
  ]
}

# Instance Template
resource "google_compute_instance_template" "default" {
  name_prefix = "${var.instance_template_name}-"
  description = "Instance template for backend servers"
  project     = var.project_id

  machine_type = var.machine_type

  disk {
    source_image = var.boot_image
    disk_size_gb = var.boot_disk_size
    disk_type    = var.boot_disk_type
    boot         = true
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id

    access_config {
      nat_ip = google_compute_address.nat_ip[0].address
    }
  }

  service_account {
    email  = google_service_account.backend_sa.email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = var.startup_script

  tags = var.network_tags

  labels = var.labels

  lifecycle {
    create_before_destroy = true
  }
}

# Instance Group Manager
resource "google_compute_instance_group_manager" "default" {
  name               = var.instance_group_name
  base_instance_name = var.instance_base_name
  zone               = var.zone
  project            = var.project_id

  version {
    instance_template = google_compute_instance_template.default.id
    name              = "primary"
  }

  target_size = var.target_size

  auto_scaling_policy {
    min_replicas    = var.min_replicas
    max_replicas    = var.max_replicas
    cooldown_period = var.cooldown_period

    cpu_utilization {
      target = var.cpu_target_utilization
    }

    load_balancing_utilization {
      target = var.load_balancing_utilization
    }
  }

  named_port {
    name = var.port_name
    port = var.backend_port
  }

  depends_on = [
    google_compute_instance_template.default
  ]
}

# URL Map
resource "google_compute_url_map" "default" {
  name            = var.url_map_name
  description     = "URL Map for load balancer"
  project         = var.project_id
  default_service = google_compute_backend_service.default.id

  dynamic "host_rule" {
    for_each = var.host_rules
    content {
      hosts        = host_rule.value.hosts
      path_matcher = host_rule.value.path_matcher
    }
  }

  dynamic "path_matcher" {
    for_each = var.path_matchers
    content {
      name            = path_matcher.value.name
      default_service = path_matcher.value.default_service
      dynamic "path_rule" {
        for_each = path_matcher.value.path_rules != null ? path_matcher.value.path_rules : []
        content {
          paths   = path_rule.value.paths
          service = path_rule.value.service
        }
      }
    }
  }
}

# SSL Certificate
resource "google_compute_ssl_certificate" "default" {
  count       = var.enable_ssl ? 1 : 0
  name_prefix = "${var.ssl_cert_name}-"
  description = "SSL Certificate for load balancer"
  project     = var.project_id

  certificate = file(var.certificate_file)
  private_key = file(var.private_key_file)

  lifecycle {
    create_before_destroy = true
  }
}

# HTTPS Proxy
resource "google_compute_target_https_proxy" "default" {
  count            = var.enable_ssl ? 1 : 0
  name             = var.https_proxy_name
  url_map          = google_compute_url_map.default.id
  ssl_certificates = [google_compute_ssl_certificate.default[0].id]
  project          = var.project_id

  ssl_policy = google_compute_ssl_policy.default[0].id
}

# HTTP Proxy
resource "google_compute_target_http_proxy" "default" {
  name    = var.http_proxy_name
  url_map = google_compute_url_map.default.id
  project = var.project_id
}

# SSL Policy
resource "google_compute_ssl_policy" "default" {
  count           = var.enable_ssl ? 1 : 0
  name            = var.ssl_policy_name
  profile         = var.ssl_profile
  min_tls_version = var.min_tls_version
  project         = var.project_id
}

# Global Forwarding Rule (HTTPS)
resource "google_compute_global_forwarding_rule" "https" {
  count                 = var.enable_ssl ? 1 : 0
  name                  = "${var.forwarding_rule_name}-https"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "443"
  target                = google_compute_target_https_proxy.default[0].id
  project               = var.project_id
  address               = google_compute_global_address.lb_address.id
}

# Global Forwarding Rule (HTTP)
resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.forwarding_rule_name}-http"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  project               = var.project_id
  address               = google_compute_global_address.lb_address.id
}

# Global Static IP Address
resource "google_compute_global_address" "lb_address" {
  name            = "${var.forwarding_rule_name}-ip"
  address_type    = "EXTERNAL"
  ip_version      = "IPV4"
  project         = var.project_id
}

# VPC Network
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  project                 = var.project_id
}

# Subnet
resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
  project       = var.project_id
}

# Firewall Rule
resource "google_compute_firewall" "allow_lb" {
  name    = "${var.vpc_name}-allow-lb"
  network = google_compute_network.vpc.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = var.network_tags
}

# Static External IP for Instances
resource "google_compute_address" "nat_ip" {
  count   = var.enable_nat_ip ? 1 : 0
  name    = "${var.instance_base_name}-nat-ip"
  region  = var.region
  project = var.project_id
}

# Service Account for Backend Instances
resource "google_service_account" "backend_sa" {
  account_id   = var.service_account_id
  display_name = "Service Account for Backend Instances"
  project      = var.project_id
}

# IAM Binding for Service Account
resource "google_project_iam_member" "backend_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

resource "google_project_iam_member" "backend_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

output "load_balancer_ip" {
  description = "External IP address of the load balancer"
  value       = google_compute_global_address.lb_address.address
}

output "backend_service_id" {
  description = "ID of the backend service"
  value       = google_compute_backend_service.default.id
}

output "instance_group_id" {
  description = "ID of the instance group manager"
  value       = google_compute_instance_group_manager.default.id
}
