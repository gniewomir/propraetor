#!/usr/bin/env bash
# Component Setup input handoff (Host Volume contract).
# ensure-components places operator-staged ACME / Database admin files here;
# Edge and Database Setup read these paths — not ephemeral /tmp handoff strings.
# Sourced by ensure-components-host and by Edge/Database Setup when resolving
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
