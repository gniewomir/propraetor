# Domain assignment projection for the Durable module (ADR-0021 / ADR-0051).
# Prefer domains.override.json when present; otherwise domains.json.
# Environments root: TF_VAR_environments_root when set; else Stack-relative default.

locals {
  environments_root_effective = (
    var.environments_root != ""
    ? var.environments_root
    : "${path.root}/../../environments"
  )
  domains_dir            = "${local.environments_root_effective}/${local.environment_slug}"
  domains_override_path  = "${local.domains_dir}/domains.override.json"
  domains_committed_path = "${local.domains_dir}/domains.json"
  domains_path = (
    fileexists(local.domains_override_path)
    ? local.domains_override_path
    : local.domains_committed_path
  )
  domains_raw = fileexists(local.domains_path) ? jsondecode(file(local.domains_path)) : {}
  domains = {
    for zone, cfg in local.domains_raw : zone => {
      names = [for name in cfg.names : name]
    }
  }
}

check "domains_names_nonempty" {
  assert {
    condition = alltrue([
      for _zone, cfg in local.domains : length(cfg.names) > 0
    ])
    error_message = "Each Domain must declare at least one name (A → Reserved IP)."
  }
}
