terraform {
  required_version = ">= 1.5.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.100.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.1"
    }
  }
}
