locals {
  domain_a_records = {
    for pair in flatten([
      for zone, config in var.domains : [
        for name in config.names : {
          key  = "${zone}:${name}"
          zone = zone
          name = name
        }
      ]
    ]) : pair.key => pair
  }
}

resource "digitalocean_project" "propraetor" {
  name        = var.names.project
  description = "Propraetor-managed projects infrastructure"
  purpose     = "Shared projects infrastructure"
  environment = "Production"
  is_default  = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_volume" "web" {
  region                  = var.region
  name                    = var.names.volume
  size                    = 5
  initial_filesystem_type = "ext4"
  description             = "Host Volume for durable data surviving Host rebuilds (ADR-0009)"

  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_reserved_ip" "web" {
  region = var.region

  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_domain" "this" {
  for_each = var.domains

  name = each.key

  lifecycle {
    prevent_destroy = true
  }
}

resource "digitalocean_record" "a" {
  for_each = local.domain_a_records

  domain = digitalocean_domain.this[each.value.zone].id
  type   = "A"
  name   = each.value.name
  value  = digitalocean_reserved_ip.web.ip_address
  ttl    = 1800

  lifecycle {
    prevent_destroy = true
  }
}

# This resource is the sole owner of Durable Cloud Project memberships. The
# Cloud Project itself owns metadata only. Use the Reserved IP resource URN
# (do:reservedip:<ip>): the Projects list API returns that shape, while
# do:floatingip:<ip> assignment drifts on every refresh and can drop siblings.
resource "digitalocean_project_resources" "durables" {
  project = digitalocean_project.propraetor.id
  resources = concat(
    [
      digitalocean_volume.web.urn,
      digitalocean_reserved_ip.web.urn,
    ],
    [for domain in digitalocean_domain.this : domain.urn],
  )

  lifecycle {
    prevent_destroy = true
  }
}

# Terraform lifecycle arguments require literals. Teardown pairs its explicit
# variable with a temporary override file; mismatches fail before provider work.
resource "terraform_data" "destroy_unlock_gate" {
  input = var.allow_destroy

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.allow_destroy == fileexists("${path.module}/durable_destroy_override.tf")
      error_message = <<-EOT
        allow_durable_destroy must match the Durable module override.
        Use ./teardown.sh to remove Durables; do not leave the unlock armed.
      EOT
    }
  }
}
