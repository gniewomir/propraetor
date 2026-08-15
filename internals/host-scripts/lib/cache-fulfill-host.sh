#!/usr/bin/env bash
# Cache Declaration gather + fulfill (ADR-0055 / #222 / #224).
# Intent-run + Requires cache:true → ACL user / client cert + published binding.
# Non-claimants → unpublish binding + ACL user `off`; durable clients until Orphan Reap (#225).
# Sourced by Cache Setup. Expects ambient after cache_setup begin:
#   DATA_ROOT, ADMIN_ENV, HOME_DIR, UNIT_DIR, USER_NAME, WORKLOADS_ROOT
# Requires: quadlet_user, cache_tls_ensure_client, cache_write_acl_file,
#           cache_admin_user_from_env, workload_manifest_intent,
#           artifact_requires_cache.

_cache_fulfill_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workload-manifest-host.sh
source "${_cache_fulfill_lib_dir}/workload-manifest-host.sh"
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

# Platform User path for one Workload's published Cache binding directory.
workload_cache_binding_dir() {
  local wl_name="${1:?workload name required}"
  printf '%s/.config/platform/workloads/%s/cache\n' "${HOME_DIR}" "${wl_name}"
}

workload_cache_dropin_path() {
  local container_base="${1:?container basename required}"
  printf '%s/%s.d/50-platform-cache.conf\n' "${UNIT_DIR}" "${container_base}"
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

# Publish binding + Setup-owned Quadlet drop-in for one Workload.
cache_publish_binding() {
  local wl_name="${1:?cache_publish_binding: workload name required}"
  local binding_dir client_dir ca_crt client_crt client_key env_path
  local sot_systemd base dropin_path mount_root

  client_dir="${DATA_ROOT}/clients/${wl_name}"
  ca_crt="${DATA_ROOT}/ca/ca.crt"
  client_crt="${client_dir}/client.crt"
  client_key="${client_dir}/client.key"
  [[ -f "${ca_crt}" && -f "${client_crt}" && -f "${client_key}" ]] || {
    echo "Cache publish: client material missing for '${wl_name}'" >&2
    return 1
  }

  binding_dir="$(workload_cache_binding_dir "${wl_name}")"
  mkdir -p "${binding_dir}"
  install -m 0644 "${ca_crt}" "${binding_dir}/ca.crt"
  install -m 0644 "${client_crt}" "${binding_dir}/client.crt"
  install -m 0600 "${client_key}" "${binding_dir}/client.key"

  mount_root=/etc/platform-cache
  env_path="${binding_dir}/environment"
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

  sot_systemd="${WORKLOADS_ROOT}/${wl_name}/systemd"
  if [[ -d "${sot_systemd}" ]]; then
    for base in "${sot_systemd}"/*.container; do
      [[ -f "${base}" ]] || continue
      base="$(basename "${base}")"
      dropin_path="$(workload_cache_dropin_path "${base}")"
      mkdir -p "$(dirname "${dropin_path}")"
      cat >"${dropin_path}" <<EOF
[Container]
EnvironmentFile=${env_path}
Volume=${binding_dir}/ca.crt:${mount_root}/ca.crt:ro
Volume=${binding_dir}/client.crt:${mount_root}/client.crt:ro
Volume=${binding_dir}/client.key:${mount_root}/client.key:ro
EOF
      if [[ -n "${USER_NAME:-}" ]]; then
        chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${dropin_path}")" 2>/dev/null || true
      fi
    done
  fi

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${binding_dir}")" 2>/dev/null || true
  fi
}

# Clear published binding + Setup-owned drop-ins for one Workload (Intent stop / non-claim).
# Retains Host Volume client material until Orphan Reap (#225); ACL disable is via
# cache_write_acl_file (user off) on the same fulfill pass.
# When SoT is already gone, clears the binding dir and conventional drop-in leftover.
cache_unpublish_binding() {
  local wl_name="${1:?cache_unpublish_binding: workload name required}"
  local binding_dir sot_systemd base dropin_path dropin_dir wl_cfg_dir

  binding_dir="$(workload_cache_binding_dir "${wl_name}")"
  rm -rf "${binding_dir}"
  wl_cfg_dir="$(dirname "${binding_dir}")"
  if [[ -d "${wl_cfg_dir}" ]] && [[ -z "$(ls -A "${wl_cfg_dir}" 2>/dev/null || true)" ]]; then
    rmdir "${wl_cfg_dir}" 2>/dev/null || true
  fi

  sot_systemd="${WORKLOADS_ROOT}/${wl_name}/systemd"
  if [[ -d "${sot_systemd}" ]]; then
    for base in "${sot_systemd}"/*.container; do
      [[ -f "${base}" ]] || continue
      base="$(basename "${base}")"
      dropin_path="$(workload_cache_dropin_path "${base}")"
      rm -f "${dropin_path}"
      dropin_dir="$(dirname "${dropin_path}")"
      if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
        rmdir "${dropin_dir}" 2>/dev/null || true
      fi
    done
  else
    dropin_path="$(workload_cache_dropin_path "${wl_name}.container")"
    rm -f "${dropin_path}"
    dropin_dir="$(dirname "${dropin_path}")"
    if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
      rmdir "${dropin_dir}" 2>/dev/null || true
    fi
  fi
}

# Reload Valkey ACL from Persist (entrypoint copies aclfile to a runtime path).
cache_acl_reload() {
  local admin_user=""
  local admin_pass=""
  local line

  admin_user="$(cache_admin_user_from_env "${ADMIN_ENV}")" || return 1
  line="$(grep -E '^CACHE_ADMIN_PASSWORD=' "${ADMIN_ENV}" | head -n1)" || true
  admin_pass="${line#CACHE_ADMIN_PASSWORD=}"
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

# True if basename is listed in the sorted claimants file.
_cache_is_claimant() {
  local wl_name="$1"
  local claimants_file="$2"
  grep -Fxq "${wl_name}" "${claimants_file}" 2>/dev/null
}

# Print 1 when the Workload tree is Intent-run and Requires cache: true, else 0.
# Fail closed on invalid Manifest Intent or Requires. Manifest does not participate.
cache_workload_is_run_claimant() {
  local wl_dir="${1:?cache_workload_is_run_claimant: workload tree required}"
  local intent claims
  intent="$(workload_manifest_intent "${wl_dir}/manifest.json")" || return 1
  [[ "${intent}" == "run" ]] || {
    printf '0\n'
    return 0
  }
  claims="$(artifact_requires_cache "${wl_dir}/requires.json")" || return 1
  printf '%s\n' "${claims}"
}

# Gather Intent-run Requires cache:true claimants; create cert/ACL + publish.
# Non-claimants: unpublish binding + ACL user off; client material until Orphan Reap.
cache_fulfill_declarations() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"
  local wl_dir wl_name claims
  local claimants_file sorted_file
  local had_binding
  local IFS

  if [[ -z "${workloads_root}" ]]; then
    echo "cache_fulfill_declarations: workloads root required" >&2
    return 1
  fi

  command -v python3 >/dev/null || {
    echo "cache_fulfill_declarations: python3 required" >&2
    return 1
  }

  claimants_file="$(mktemp "${TMPDIR:-/tmp}/platform-cache-claimants.XXXXXX")"
  sorted_file="$(mktemp "${TMPDIR:-/tmp}/platform-cache-claimants-sorted.XXXXXX")"
  : >"${claimants_file}"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if [[ "${wl_name}" == "cache" ]]; then
        rm -f "${claimants_file}" "${sorted_file}"
        echo "Cache gather: Workload basename 'cache' is reserved" >&2
        return 1
      fi
      claims="$(cache_workload_is_run_claimant "${wl_dir}")" || {
        rm -f "${claimants_file}" "${sorted_file}"
        return 1
      }
      [[ "${claims}" == "1" ]] || continue
      if ! cache_basename_is_claim_safe "${wl_name}"; then
        rm -f "${claimants_file}" "${sorted_file}"
        echo "Cache gather: Workload basename '${wl_name}' is not Cache-claim safe (*?[]:)" >&2
        return 1
      fi
      printf '%s\n' "${wl_name}" >>"${claimants_file}"
    done
  fi

  LC_ALL=C sort -u "${claimants_file}" >"${sorted_file}"
  rm -f "${claimants_file}"

  while IFS= read -r wl_name; do
    [[ -n "${wl_name}" ]] || continue
    cache_tls_ensure_client "${wl_name}" || {
      rm -f "${sorted_file}"
      return 1
    }
  done <"${sorted_file}"

  cache_write_acl_file "${ADMIN_ENV}" "${sorted_file}" || {
    rm -f "${sorted_file}"
    return 1
  }
  cache_acl_reload || {
    rm -f "${sorted_file}"
    return 1
  }

  while IFS= read -r wl_name; do
    [[ -n "${wl_name}" ]] || continue
    cache_publish_binding "${wl_name}" || {
      rm -f "${sorted_file}"
      return 1
    }
    echo "Cache: fulfilled binding for Workload '${wl_name}'" >&2
  done <"${sorted_file}"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if _cache_is_claimant "${wl_name}" "${sorted_file}"; then
        continue
      fi
      had_binding=0
      if [[ -d "$(workload_cache_binding_dir "${wl_name}")" ]]; then
        had_binding=1
      fi
      cache_unpublish_binding "${wl_name}" || {
        rm -f "${sorted_file}"
        return 1
      }
      if [[ "${had_binding}" -eq 1 ]]; then
        echo "Cache: unpublished binding for Workload '${wl_name}'" >&2
      fi
    done
  fi

  rm -f "${sorted_file}"
  return 0
}
