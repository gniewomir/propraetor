#!/usr/bin/env bash
# Cache Declaration adapter on shared Declaration converge (ADR-0055 / #227).
# Intent-run + Requires cache:true → ACL user / client cert + published binding.
# Non-claimants → unpublish binding + ACL user `off`; durable clients until Orphan Reap.
# Orphan Reap (SoT gone) → DELUSER, best-effort prefix keys, clients + clear projection
# in post-workloads.
# Sourced by Cache Setup. Expects ambient after cache_setup begin:
#   DATA_ROOT, ADMIN_ENV, HOME_DIR, UNIT_DIR, USER_NAME, WORKLOADS_ROOT
# Requires: quadlet_user, component_tls_ensure_client, cache_write_acl_file,
#           cache_admin_user_from_env, declaration converge, artifact_requires_cache.

_cache_fulfill_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=declaration-converge-host.sh
source "${_cache_fulfill_lib_dir}/declaration-converge-host.sh"
# Host Volume ships a copy of internals/lib/artifact/requires.sh beside this file
# (ensure-fabric / ensure-components). Unit Tests source this file in-tree.
_requires_lib="${_cache_fulfill_lib_dir}/requires.sh"
if [[ ! -f "${_requires_lib}" ]]; then
  _requires_lib="${_cache_fulfill_lib_dir}/../../lib/artifact/requires.sh"
fi
if [[ ! -f "${_requires_lib}" ]]; then
  echo "cache-fulfill-host: Requires library missing" >&2
  return 1
fi
# shellcheck source=../../lib/artifact/requires.sh
source "${_requires_lib}"

_CACHE_BINDING_KIND=cache
_CACHE_DROPIN_LEAF=50-platform-cache.conf
_CACHE_MOUNT_ROOT=/etc/platform-cache

# Platform User path for one Workload's published Cache binding directory.
workload_cache_binding_dir() {
  local wl_name="${1:?workload name required}"
  declaration_binding_dir "${wl_name}" "${_CACHE_BINDING_KIND}"
}

workload_cache_dropin_path() {
  local container_base="${1:?container basename required}"
  declaration_dropin_path "${container_base}" "${_CACHE_DROPIN_LEAF}"
}

# True when basename is safe for ACL key globs and CN (ADR-0055).
# Rejects glob metacharacters * ? [ ] and ':' (prefix separator).
cache_basename_is_claim_safe() {
  local basename="${1:?cache_basename_is_claim_safe: basename required}"
  [[ -n "${basename}" ]] || return 1
  case "${basename}" in
    *:*|*"/"*|*" "*|*$'\t'*) return 1 ;;
  esac
  # Glob metacharacters must not appear in ACL ~basename:* patterns.
  if [[ "${basename}" == *\** || "${basename}" == *\?* \
    || "${basename}" == *\[* || "${basename}" == *\]* ]]; then
    return 1
  fi
  return 0
}

_cache_validate_claim_basename() {
  local wl_name="${1:?}"
  if cache_basename_is_claim_safe "${wl_name}"; then
    return 0
  fi
  echo "Cache gather: Workload basename '${wl_name}' is not Cache-claim safe (*?[]:)" >&2
  return 1
}

_cache_write_binding_env() {
  local env_path="${1:?}"
  local wl_name="${2:?}"
  local mount_root="${3:?}"
  cat >"${env_path}" <<EOF
CACHE_HOST=cache
CACHE_PORT=6379
CACHE_TLS=1
CACHE_CA_CERT=${mount_root}/ca.crt
CACHE_CLIENT_CERT=${mount_root}/client.crt
CACHE_CLIENT_KEY=${mount_root}/client.key
CACHE_KEY_PREFIX=${wl_name}:
EOF
  chmod 0600 "${env_path}"
}

# Publish binding + Setup-owned Quadlet drop-in for one Workload.
cache_publish_binding() {
  local wl_name="${1:?cache_publish_binding: workload name required}"
  declaration_publish_mtls_binding \
    "${wl_name}" \
    "${_CACHE_BINDING_KIND}" \
    "${_CACHE_DROPIN_LEAF}" \
    "${_CACHE_MOUNT_ROOT}" \
    _cache_write_binding_env
}

# Clear published binding + Setup-owned drop-ins for one Workload (Intent stop / non-claim).
# Retains Host Volume client material until Orphan Reap; ACL disable is via
# cache_write_acl_file (user off) on the same fulfill pass.
cache_unpublish_binding() {
  local wl_name="${1:?cache_unpublish_binding: workload name required}"
  declaration_unpublish_mtls_binding \
    "${wl_name}" \
    "${_CACHE_BINDING_KIND}" \
    "${_CACHE_DROPIN_LEAF}"
}

# Read admin password from ADMIN_ENV (never prints; caller must not echo).
_cache_admin_password_from_env() {
  local line
  line="$(grep -E '^CACHE_ADMIN_PASSWORD=' "${ADMIN_ENV}" | head -n1)" || true
  printf '%s' "${line#CACHE_ADMIN_PASSWORD=}"
}

# Reload Valkey ACL from Persist (entrypoint copies aclfile to a runtime path).
cache_acl_reload() {
  local admin_user=""
  local admin_pass=""

  admin_user="$(cache_admin_user_from_env "${ADMIN_ENV}")" || return 1
  admin_pass="$(_cache_admin_password_from_env)"
  [[ -n "${admin_pass}" ]] || {
    echo "Cache: admin password missing for ACL reload" >&2
    return 1
  }

  quadlet_user env "HOME=${HOME_DIR}" \
    "CACHE_ACL_USER=${admin_user}" "CACHE_ACL_PASS=${admin_pass}" bash -c \
    "cd \"\$HOME\" && podman exec \
      -e CACHE_ACL_USER -e CACHE_ACL_PASS \
      cache-valkey \
      sh -c 'cp /etc/valkey/users.acl /tmp/propraetor-cache/users.acl && \
        valkey-cli --tls \
          --cacert /etc/cache-certs/ca.crt \
          --cert /etc/cache-certs/admin.crt \
          --key /etc/cache-certs/admin.key \
          --user \"\$CACHE_ACL_USER\" \
          -a \"\$CACHE_ACL_PASS\" \
          ACL LOAD'" \
    >/dev/null || {
    echo "Cache: ACL LOAD failed" >&2
    return 1
  }
}

# Drop ACL user named by basename (idempotent when already absent).
cache_acl_deluser() {
  local basename="${1:?cache_acl_deluser: basename required}"
  local admin_user=""
  local admin_pass=""

  admin_user="$(cache_admin_user_from_env "${ADMIN_ENV}")" || return 1
  admin_pass="$(_cache_admin_password_from_env)"
  [[ -n "${admin_pass}" ]] || {
    echo "Cache: admin password missing for ACL DELUSER" >&2
    return 1
  }

  quadlet_user env "HOME=${HOME_DIR}" \
    "CACHE_ACL_USER=${admin_user}" "CACHE_ACL_PASS=${admin_pass}" \
    "CACHE_DELUSER=${basename}" bash -c \
    "cd \"\$HOME\" && podman exec \
      -e CACHE_ACL_USER -e CACHE_ACL_PASS -e CACHE_DELUSER \
      cache-valkey \
      valkey-cli --tls \
        --cacert /etc/cache-certs/ca.crt \
        --cert /etc/cache-certs/admin.crt \
        --key /etc/cache-certs/admin.key \
        --user \"\$CACHE_ACL_USER\" \
        -a \"\$CACHE_ACL_PASS\" \
        ACL DELUSER \"\$CACHE_DELUSER\"" \
    >/dev/null || {
    echo "Cache: ACL DELUSER failed for '${basename}'" >&2
    return 1
  }
}

# Best-effort delete of keys under basename: (admin KEYS + UNLINK). Never fail closed.
# Admin has +@all; KEYS is acceptable for one-tenant Orphan Reap cleanup.
cache_delete_prefix_keys_best_effort() {
  local basename="${1:?cache_delete_prefix_keys_best_effort: basename required}"
  local admin_user=""
  local admin_pass=""

  admin_user="$(cache_admin_user_from_env "${ADMIN_ENV}" 2>/dev/null)" || return 0
  admin_pass="$(_cache_admin_password_from_env)"
  [[ -n "${admin_pass}" ]] || return 0

  quadlet_user env "HOME=${HOME_DIR}" \
    "CACHE_ACL_USER=${admin_user}" "CACHE_ACL_PASS=${admin_pass}" \
    "CACHE_MATCH=${basename}:*" bash -c \
    "cd \"\$HOME\" && podman exec \
      -e CACHE_ACL_USER -e CACHE_ACL_PASS -e CACHE_MATCH \
      cache-valkey \
      sh -c '
        cli() {
          valkey-cli --tls \
            --cacert /etc/cache-certs/ca.crt \
            --cert /etc/cache-certs/admin.crt \
            --key /etc/cache-certs/admin.key \
            --user \"\$CACHE_ACL_USER\" \
            -a \"\$CACHE_ACL_PASS\" \
            \"\$@\"
        }
        keys=\$(cli --raw KEYS \"\$CACHE_MATCH\") || exit 0
        [ -z \"\$keys\" ] && exit 0
        printf \"%s\\n\" \"\$keys\" | while IFS= read -r k; do
          [ -n \"\$k\" ] || continue
          cli UNLINK \"\$k\" >/dev/null || true
        done
      '" \
    >/dev/null 2>&1 || true
}

# Full drop for one basename: best-effort prefix keys, DELUSER, unpublish, rm clients.
# Runtime DELUSER before rm clients so a failed DELUSER remains selectable on retry (#225).
cache_drop_fulfillment() {
  local wl_name="${1:?cache_drop_fulfillment: workload name required}"
  local client_dir="${DATA_ROOT}/clients/${wl_name}"

  cache_delete_prefix_keys_best_effort "${wl_name}"
  cache_acl_deluser "${wl_name}" || return 1
  cache_unpublish_binding "${wl_name}" || return 1
  rm -rf "${client_dir}"
  echo "Cache: dropped fulfillment for Workload '${wl_name}'" >&2
}

# Print client basenames under CLIENTS_DIR whose Workload SoT Manifest is gone.
cache_absent_client_basenames() {
  declaration_absent_client_basenames "$@"
}

# post-workloads: DELUSER + keys + clients + clear projection for Orphan-absent basenames.
cache_drop_absent_fulfillments() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"
  local clients_dir="${CLIENTS_DIR:-${DATA_ROOT}/clients}"

  if [[ -z "${workloads_root}" ]]; then
    echo "cache_drop_absent_fulfillments: workloads root required" >&2
    return 1
  fi

  declaration_drop_absent_fulfillments \
    "${workloads_root}" \
    "${clients_dir}" \
    cache_drop_fulfillment
}

# Print 1 when the Workload tree is Intent-run and Requires cache: true, else 0.
cache_workload_is_run_claimant() {
  local wl_dir="${1:?cache_workload_is_run_claimant: workload tree required}"
  declaration_workload_is_run_claimant "${wl_dir}" artifact_requires_cache
}

# Ensure client certs for every claimant, rewrite ACL, reload.
_cache_prepare_claimants() {
  local sorted_file="${1:?}"
  local wl_name

  while IFS= read -r wl_name; do
    [[ -n "${wl_name}" ]] || continue
    component_tls_ensure_client cache "${DATA_ROOT}" "${wl_name}" || return 1
  done <"${sorted_file}"

  cache_write_acl_file "${ADMIN_ENV}" "${sorted_file}" || return 1
  cache_acl_reload || return 1
}

# Gather Intent-run Requires cache:true claimants; create cert/ACL + publish.
# Non-claimants: unpublish binding + ACL user off; client material until Orphan Reap.
cache_fulfill_declarations() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"

  if [[ -z "${workloads_root}" ]]; then
    echo "cache_fulfill_declarations: workloads root required" >&2
    return 1
  fi

  declaration_converge_claims \
    "${workloads_root}" \
    "Cache" \
    "cache" \
    cache_workload_is_run_claimant \
    _cache_validate_claim_basename \
    _cache_prepare_claimants \
    cache_publish_binding \
    cache_unpublish_binding \
    workload_cache_binding_dir
}
