# Define the Provider
provider "google" {
  project = "YOUR_PROJECT_ID" # Replace with your actual Project ID
  region  = "us-central1"
}

# 1. The Compute Instance
resource "google_compute_instance" "ajith_vm" {
  name         = "ajith-vm"
  machine_type = "e2-standard-2"
  zone         = "us-central1-a"

  # Applying the tag so the firewall rule finds it
  tags = ["ssh-enabled"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 10 # GCP warns about performance below 200GB, but this works
    }
  }

  network_interface {
    network = "default"
    access_config {
      # Include this block to give the VM an External IP
    }
  }
}

# 2. The Firewall Rule
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh-anywhere"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Allow from any host
  source_ranges = ["0.0.0.0/0"]
  
  # Only applies to VMs with this tag
  target_tags = ["ssh-enabled"]
}
