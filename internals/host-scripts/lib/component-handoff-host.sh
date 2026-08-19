#!/usr/bin/env bash
# Component Setup input handoff (Host Volume contract).
# ensure-components places operator-staged ACME / Identity / Database / Cache admin files here;
# Edge, Identity, Database, and Cache Setup read these paths — not ephemeral /tmp handoff strings.
# Sourced by ensure-components-host and by Component Setup when resolving
# default stage paths. Ambient: HV_ROOT (via host_volume_* path vocabulary).

_component_handoff_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-volume-paths-host.sh
source "${_component_handoff_lib_dir}/host-volume-paths-host.sh"

component_handoff_root() {
  # Sibling of Component owner trees — not nested Persist (ADR-0054).
  printf '%s\n' "$(host_volume_components_sot_root)/handoff"
}

component_handoff_acme_want_list() {
  printf '%s\n' "$(component_handoff_root)/acme-want-list"
}

component_handoff_acme_env() {
  printf '%s\n' "$(component_handoff_root)/acme.env"
}

component_handoff_database_admin_env() {
  printf '%s\n' "$(component_handoff_root)/database-admin.env"
}

component_handoff_cache_admin_env() {
  printf '%s\n' "$(component_handoff_root)/cache-admin.env"
}

component_handoff_identity_config() {
  printf '%s\n' "$(component_handoff_root)/identity.json"
}

component_handoff_identity_admin_env() {
  printf '%s\n' "$(component_handoff_root)/identity-admin.env"
}

component_handoff_environment_slug_file() {
  printf '%s\n' "$(component_handoff_root)/environment-slug"
}

# Read staged Environment cloud slug from handoff (ADR-0057 / #253).
component_handoff_environment_slug() {
  local path slug
  path="$(component_handoff_environment_slug_file)"
  [[ -f "${path}" ]] || {
    echo "ensure-components: Environment slug handoff missing at ${path}" >&2
    return 1
  }
  slug="$(tr -d '[:space:]' <"${path}")"
  [[ -n "${slug}" ]] || {
    echo "ensure-components: Environment slug handoff empty at ${path}" >&2
    return 1
  }
  printf '%s\n' "${slug}"
}

# Fail closed if ACME handoff files are missing before Edge Component Setup.
component_handoff_require_acme() {
  local want env
  want="$(component_handoff_acme_want_list)"
  env="$(component_handoff_acme_env)"
  [[ -f "${want}" ]] || {
    echo "ensure-components: ACME FQDN handoff missing at ${want}" >&2
    return 1
  }
  [[ -f "${env}" ]] || {
    echo "ensure-components: ACME EnvironmentFile handoff missing at ${env}" >&2
    return 1
  }
}

# Install operator-staged ACME want-list + EnvironmentFile into the handoff root.
# Args: staged_want_list staged_acme_env
component_handoff_install_acme() {
  local want_src="${1:?component_handoff_install_acme: staged want-list required}"
  local env_src="${2:?component_handoff_install_acme: staged ACME EnvironmentFile required}"
  local root want_dst env_dst
  root="$(component_handoff_root)"
  want_dst="$(component_handoff_acme_want_list)"
  env_dst="$(component_handoff_acme_env)"
  [[ -f "${want_src}" ]] || {
    echo "ensure-components: staged ACME FQDN list missing at ${want_src}" >&2
    return 1
  }
  [[ -f "${env_src}" ]] || {
    echo "ensure-components: staged ACME EnvironmentFile missing at ${env_src}" >&2
    return 1
  }
  mkdir -p "${root}"
  install -m 0644 "${want_src}" "${want_dst}"
  install -m 0644 "${env_src}" "${env_dst}"
}

# Install operator-staged Database admin EnvironmentFile into the handoff root.
# Args: staged_admin_env
component_handoff_install_database_admin() {
  local src="${1:?component_handoff_install_database_admin: staged EnvironmentFile required}"
  local root dst
  root="$(component_handoff_root)"
  dst="$(component_handoff_database_admin_env)"
  [[ -f "${src}" ]] || {
    echo "ensure-components: staged Database admin EnvironmentFile missing at ${src}" >&2
    return 1
  }
  mkdir -p "${root}"
  install -m 0600 "${src}" "${dst}"
}

# Install operator-staged Cache admin EnvironmentFile into the handoff root.
# Args: staged_admin_env
component_handoff_install_cache_admin() {
  local src="${1:?component_handoff_install_cache_admin: staged EnvironmentFile required}"
  local root dst
  root="$(component_handoff_root)"
  dst="$(component_handoff_cache_admin_env)"
  [[ -f "${src}" ]] || {
    echo "ensure-components: staged Cache admin EnvironmentFile missing at ${src}" >&2
    return 1
  }
  mkdir -p "${root}"
  install -m 0600 "${src}" "${dst}"
}

# Install operator-staged Environment cloud slug into the handoff root.
# Args: staged_slug_file
component_handoff_install_environment_slug() {
  local src="${1:?component_handoff_install_environment_slug: staged slug file required}"
  local root dst slug
  root="$(component_handoff_root)"
  dst="$(component_handoff_environment_slug_file)"
  [[ -f "${src}" ]] || {
    echo "ensure-components: staged Environment slug missing at ${src}" >&2
    return 1
  }
  slug="$(tr -d '[:space:]' <"${src}")"
  [[ -n "${slug}" ]] || {
    echo "ensure-components: staged Environment slug empty at ${src}" >&2
    return 1
  }
  mkdir -p "${root}"
  printf '%s\n' "${slug}" >"${dst}"
}

# Install operator-staged identity.json + Identity admin EnvironmentFile into the handoff root.
# Args: staged_identity_json staged_identity_admin_env
component_handoff_install_identity() {
  local config_src="${1:?component_handoff_install_identity: staged identity.json required}"
  local admin_src="${2:?component_handoff_install_identity: staged Identity admin EnvironmentFile required}"
  local root config_dst admin_dst
  root="$(component_handoff_root)"
  config_dst="$(component_handoff_identity_config)"
  admin_dst="$(component_handoff_identity_admin_env)"
  [[ -f "${config_src}" ]] || {
    echo "ensure-components: staged identity.json missing at ${config_src}" >&2
    return 1
  }
  [[ -f "${admin_src}" ]] || {
    echo "ensure-components: staged Identity admin EnvironmentFile missing at ${admin_src}" >&2
    return 1
  }
  mkdir -p "${root}"
  install -m 0644 "${config_src}" "${config_dst}"
  install -m 0600 "${admin_src}" "${admin_dst}"
}

# Fail closed if Identity handoff files are missing before Component Setup.
component_handoff_require_identity() {
  local config admin slug_path
  config="$(component_handoff_identity_config)"
  admin="$(component_handoff_identity_admin_env)"
  slug_path="$(component_handoff_environment_slug_file)"
  [[ -f "${config}" ]] || {
    echo "ensure-components: Identity config handoff missing at ${config}" >&2
    return 1
  }
  [[ -f "${admin}" ]] || {
    echo "ensure-components: Identity admin EnvironmentFile handoff missing at ${admin}" >&2
    return 1
  }
  [[ -f "${slug_path}" ]] || {
    echo "ensure-components: Environment slug handoff missing at ${slug_path}" >&2
    return 1
  }
}
