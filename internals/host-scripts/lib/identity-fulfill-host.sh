#!/usr/bin/env bash
# Identity permission catalog + OIDC client gather + Pocket ID fulfill (ADR-0057 / #253 / #254 / #256).
# Intent stop unpublishes bindings and leaves Pocket ID interior records until Orphan Reap.
# Merges Intent-run API catalog Declarations into one Environment-scoped Pocket ID API
# (resource / JWT aud = propreator:${env-slug}), full-replaces permissions by key,
# registers public + PKCE OIDC clients keyed by Workload basename, grants api-access
# for requested permission keys, and publishes resource-server / client bindings.
#
# Sourced by Identity Setup. Expects ambient after identity_standing_ensure:
#   DATA_ROOT, ADMIN_ENV, HOME_DIR, UNIT_DIR, USER_NAME, WORKLOADS_ROOT, ENV_SLUG
#
# Requires: quadlet_user, component_handoff_environment_slug,
#           identity pocket-id admin helpers, artifact requires/provides readers.

_identity_fulfill_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=declaration-converge-host.sh
source "${_identity_fulfill_lib_dir}/declaration-converge-host.sh"
# shellcheck source=component-handoff-host.sh
source "${_identity_fulfill_lib_dir}/component-handoff-host.sh"
# shellcheck source=identity-pocket-id-admin-host.sh
source "${_identity_fulfill_lib_dir}/identity-pocket-id-admin-host.sh"

_identity_resource_lib="${_identity_fulfill_lib_dir}/../../lib/identity/identity-resource.sh"
if [[ ! -f "${_identity_resource_lib}" ]]; then
  _identity_resource_lib="${_identity_fulfill_lib_dir}/identity-resource.sh"
fi
if [[ ! -f "${_identity_resource_lib}" ]]; then
  echo "identity-fulfill-host: identity-resource library missing" >&2
  return 1
fi
# shellcheck source=../../lib/identity/identity-resource.sh
source "${_identity_resource_lib}"

_requires_lib="${_identity_fulfill_lib_dir}/requires.sh"
if [[ ! -f "${_requires_lib}" ]]; then
  _requires_lib="${_identity_fulfill_lib_dir}/../../lib/artifact/requires.sh"
fi
if [[ ! -f "${_requires_lib}" ]]; then
  echo "identity-fulfill-host: Requires library missing" >&2
  return 1
fi
# shellcheck source=../../lib/artifact/requires.sh
source "${_requires_lib}"

_provides_lib="${_identity_fulfill_lib_dir}/provides.sh"
if [[ ! -f "${_provides_lib}" ]]; then
  _provides_lib="${_identity_fulfill_lib_dir}/../../lib/artifact/provides.sh"
fi
if [[ ! -f "${_provides_lib}" ]]; then
  echo "identity-fulfill-host: Provides library missing" >&2
  return 1
fi
# shellcheck source=../../lib/artifact/provides.sh
source "${_provides_lib}"

_IDENTITY_BINDING_KIND=identity
_IDENTITY_DROPIN_LEAF=50-platform-identity.conf
_IDENTITY_MOUNT_ROOT=/etc/platform-identity

workload_identity_binding_dir() {
  local wl_name="${1:?workload name required}"
  declaration_binding_dir "${wl_name}" "${_IDENTITY_BINDING_KIND}"
}

workload_identity_dropin_path() {
  local container_base="${1:?container basename required}"
  declaration_dropin_path "${container_base}" "${_IDENTITY_DROPIN_LEAF}"
}

# Print 1 when Workload carries an API permission catalog Declaration, else 0.
identity_catalog_workload_has_declaration() {
  local wl_dir="${1:?identity_catalog_workload_has_declaration: workload tree required}"
  local has_catalog has_identity
  has_identity="$(artifact_requires_identity "${wl_dir}/requires.json")" || return 1
  [[ "${has_identity}" == "1" ]] || {
    printf '0\n'
    return 0
  }
  has_catalog="$(artifact_provides_has_permissions "${wl_dir}/provides.json")" || return 1
  printf '%s\n' "${has_catalog}"
}

# Print 1 when Intent-run Identity API catalog claimant, else 0.
identity_catalog_workload_is_run_claimant() {
  local wl_dir="${1:?identity_catalog_workload_is_run_claimant: workload tree required}"
  local intent
  [[ "$(identity_catalog_workload_has_declaration "${wl_dir}")" == "1" ]] || {
    printf '0\n'
    return 0
  }
  intent="$(workload_manifest_intent "${wl_dir}/manifest.json")" || return 1
  if [[ "${intent}" == "run" ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

# Print 1 when Workload carries an OIDC client Declaration, else 0.
identity_client_workload_has_declaration() {
  local wl_dir="${1:?identity_client_workload_has_declaration: workload tree required}"
  local has_identity has_callback has_permissions
  has_identity="$(artifact_requires_identity "${wl_dir}/requires.json")" || return 1
  [[ "${has_identity}" == "1" ]] || {
    printf '0\n'
    return 0
  }
  has_callback="$(artifact_provides_has_oidc_callback "${wl_dir}/provides.json")" || return 1
  [[ "${has_callback}" == "1" ]] || {
    printf '0\n'
    return 0
  }
  has_permissions="$(artifact_requires_has_permissions "${wl_dir}/requires.json")" || return 1
  printf '%s\n' "${has_permissions}"
}

# Print 1 when Intent-run Identity OIDC client claimant, else 0.
identity_client_workload_is_run_claimant() {
  local wl_dir="${1:?identity_client_workload_is_run_claimant: workload tree required}"
  local intent
  [[ "$(identity_client_workload_has_declaration "${wl_dir}")" == "1" ]] || {
    printf '0\n'
    return 0
  }
  intent="$(workload_manifest_intent "${wl_dir}/manifest.json")" || return 1
  if [[ "${intent}" == "run" ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

# Deterministic callback URLs from Binding FQDNs + Provides.oidc_callback path.
# Prints JSON array on stdout.
identity_client_callback_urls_json() {
  local wl_dir="${1:?identity_client_callback_urls_json: workload tree required}"
  python3 - "${wl_dir}" <<'PY'
import json, os, sys

wl_dir = sys.argv[1]
binding_path = os.path.join(wl_dir, "binding.json")
provides_path = os.path.join(wl_dir, "provides.json")
if not os.path.isfile(binding_path):
    raise SystemExit(f"Identity gather: OIDC client missing binding.json: {binding_path}")
with open(binding_path, encoding="utf-8") as f:
    binding = json.load(f)
with open(provides_path, encoding="utf-8") as f:
    provides = json.load(f)
callback_path = provides.get("oidc_callback")
if not isinstance(callback_path, str) or not callback_path.startswith("/"):
    raise SystemExit(f"Identity gather: invalid provides.oidc_callback in {provides_path}")
domains = binding.get("domains") or {}
if not isinstance(domains, dict) or not domains:
    raise SystemExit(f"Identity gather: OIDC client requires ≥1 Binding FQDN: {binding_path}")
urls = [f"https://{fqdn}{callback_path}" for fqdn in sorted(domains)]
print(json.dumps(urls))
PY
}

# Resolve permission keys against Environment-scoped API JSON; print JSON array of UUIDs.
identity_permission_ids_for_keys_json() {
  local api_json="${1:?identity_permission_ids_for_keys_json: api json required}"
  local keys_file="${2:?identity_permission_ids_for_keys_json: keys file required}"
  python3 - "${api_json}" "${keys_file}" <<'PY'
import json, sys

api = json.loads(sys.argv[1])
wanted = []
with open(sys.argv[2], encoding="utf-8") as f:
    for line in f:
        key = line.strip()
        if key:
            wanted.append(key)
by_key = {p["key"]: p["id"] for p in api.get("permissions") or []}
missing = sorted(k for k in wanted if k not in by_key)
if missing:
    raise SystemExit(
        "Identity gather: requested permission keys missing from Environment catalog: "
        + ", ".join(missing)
    )
print(json.dumps([by_key[k] for k in wanted]))
PY
}

identity_converge_oidc_client() {
  local client_id="${1:?identity_converge_oidc_client: client id required}"
  local callback_urls_json="${2:?identity_converge_oidc_client: callback urls required}"
  local display_name="${3:-${client_id}}"
  local existing=""

  if existing="$(identity_pocket_id_oidc_client_get "${client_id}" 2>/dev/null || true)" && \
    [[ -n "${existing}" ]]; then
    identity_pocket_id_oidc_client_update "${client_id}" "${display_name}" true \
      "${callback_urls_json}" || return 1
  else
    identity_pocket_id_oidc_client_create "${client_id}" "${display_name}" true \
      "${callback_urls_json}" || return 1
  fi
}

identity_grant_client_api_access() {
  local client_id="${1:?identity_grant_client_api_access: client id required}"
  local api_json="${2:?identity_grant_client_api_access: api json required}"
  local keys_file="${3:?identity_grant_client_api_access: keys file required}"
  local permission_ids_json=""

  permission_ids_json="$(identity_permission_ids_for_keys_json "${api_json}" "${keys_file}")" \
    || return 1
  identity_pocket_id_api_access_put "${client_id}" "${permission_ids_json}" || return 1
}

identity_delete_oidc_client_if_present() {
  local client_id="${1:?identity_delete_oidc_client_if_present: client id required}"
  if identity_pocket_id_oidc_client_get "${client_id}" >/dev/null 2>&1; then
    identity_pocket_id_oidc_client_delete "${client_id}" || return 1
    echo "Identity: deleted OIDC client '${client_id}'" >&2
  fi
}

# Merge Provides.permissions from sorted catalog claimants file; prints JSON array
# suitable for Pocket ID PUT /permissions.
identity_merge_catalog_permissions_json() {
  local claimants_file="${1:?identity_merge_catalog_permissions_json: claimants file required}"
  local workloads_root="${2:?identity_merge_catalog_permissions_json: workloads root required}"
  python3 - "${claimants_file}" "${workloads_root}" <<'PY'
import json, os, sys

claimants_path, workloads_root = sys.argv[1], sys.argv[2]
merged = {}
with open(claimants_path, encoding="utf-8") as f:
    for line in f:
        wl = line.strip()
        if not wl:
            continue
        provides_path = os.path.join(workloads_root, wl, "provides.json")
        with open(provides_path, encoding="utf-8") as pf:
            provides = json.load(pf)
        perms = provides.get("permissions") or {}
        if not isinstance(perms, dict) or not perms:
            raise SystemExit(f"Identity gather: catalog claimant {wl!r} missing permissions")
        for key, name in perms.items():
            if key in merged and merged[key] != name:
                raise SystemExit(
                    f"Identity gather: permission key {key!r} has conflicting names "
                    f"({merged[key]!r} vs {name!r})"
                )
            merged[key] = name

out = [{"key": k, "name": merged[k], "description": ""} for k in sorted(merged)]
print(json.dumps(out))
PY
}

_identity_write_resource_server_env() {
  local env_path="${1:?}"
  local issuer="${2:?}"
  local aud="${3:?}"
  local marker_key="${4:?_identity_write_resource_server_env: marker key required}"
  cat >"${env_path}" <<EOF
IDENTITY_ISSUER=${issuer}
IDENTITY_JWKS_URL=${issuer}/.well-known/jwks.json
IDENTITY_AUD=${aud}
IDENTITY_MARKER_KEY=${marker_key}
EOF
  chmod 0644 "${env_path}"
}

_identity_write_client_env() {
  local env_path="${1:?}"
  local issuer="${2:?}"
  local client_id="${3:?}"
  local resource="${4:?}"
  local scope="${5:?}"
  local callback_urls="${6:?}"
  cat >"${env_path}" <<EOF
IDENTITY_ISSUER=${issuer}
IDENTITY_CLIENT_ID=${client_id}
IDENTITY_RESOURCE=${resource}
IDENTITY_SCOPE=${scope}
IDENTITY_CALLBACK_URLS=${callback_urls}
EOF
  chmod 0644 "${env_path}"
}

# Sync Setup-owned drop-ins to every *.env file in the Workload identity binding dir.
_identity_sync_workload_dropins() {
  local wl_name="${1:?_identity_sync_workload_dropins: workload name required}"
  local binding_dir sorted_env_file env_path sot_systemd base dropin_path dropin_dir

  binding_dir="$(workload_identity_binding_dir "${wl_name}")"

  sorted_env_file="$(mktemp "${TMPDIR:-/tmp}/identity-env-files.XXXXXX")"
  if [[ -d "${binding_dir}" ]]; then
    find "${binding_dir}" -maxdepth 1 -name '*.env' -type f 2>/dev/null \
      | LC_ALL=C sort >"${sorted_env_file}" || true
  else
    : >"${sorted_env_file}"
  fi
  # shellcheck disable=SC2064
  trap "rm -f '${sorted_env_file}'" RETURN
  sot_systemd="${WORKLOADS_ROOT}/${wl_name}/systemd"
  if [[ -d "${sot_systemd}" ]]; then
    for base in "${sot_systemd}"/*.container; do
      [[ -f "${base}" ]] || continue
      base="$(basename "${base}")"
      dropin_path="$(workload_identity_dropin_path "${base}")"
      if [[ ! -s "${sorted_env_file}" ]]; then
        rm -f "${dropin_path}"
        dropin_dir="$(dirname "${dropin_path}")"
        if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
          rmdir "${dropin_dir}" 2>/dev/null || true
        fi
        continue
      fi
      mkdir -p "$(dirname "${dropin_path}")"
      {
        printf '[Container]\n'
        while IFS= read -r env_path; do
          [[ -n "${env_path}" ]] || continue
          printf 'EnvironmentFile=%s\n' "${env_path}"
        done <"${sorted_env_file}"
      } >"${dropin_path}"
      if [[ -n "${USER_NAME:-}" ]]; then
        chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${dropin_path}")" 2>/dev/null || true
      fi
    done
  elif [[ ! -s "${sorted_env_file}" ]]; then
    dropin_path="$(workload_identity_dropin_path "${wl_name}.container")"
    rm -f "${dropin_path}"
    dropin_dir="$(dirname "${dropin_path}")"
    if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
      rmdir "${dropin_dir}" 2>/dev/null || true
    fi
  else
    dropin_path="$(workload_identity_dropin_path "${wl_name}.container")"
    mkdir -p "$(dirname "${dropin_path}")"
    {
      printf '[Container]\n'
      while IFS= read -r env_path; do
        [[ -n "${env_path}" ]] || continue
        printf 'EnvironmentFile=%s\n' "${env_path}"
      done <"${sorted_env_file}"
    } >"${dropin_path}"
    if [[ -n "${USER_NAME:-}" ]]; then
      chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${dropin_path}")" 2>/dev/null || true
    fi
  fi
}

_identity_prune_empty_binding_dir() {
  local wl_name="${1:?}"
  local binding_dir wl_cfg_dir
  binding_dir="$(workload_identity_binding_dir "${wl_name}")"
  if [[ -d "${binding_dir}" ]] && [[ -z "$(find "${binding_dir}" -mindepth 1 -maxdepth 1 -type f 2>/dev/null || true)" ]]; then
    rm -rf "${binding_dir}"
    wl_cfg_dir="$(dirname "${binding_dir}")"
    if [[ -d "${wl_cfg_dir}" ]] && [[ -z "$(ls -A "${wl_cfg_dir}" 2>/dev/null || true)" ]]; then
      rmdir "${wl_cfg_dir}" 2>/dev/null || true
    fi
  fi
}

identity_publish_resource_server_binding() {
  local wl_name="${1:?identity_publish_resource_server_binding: workload name required}"
  local issuer="${2:?identity_publish_resource_server_binding: issuer required}"
  local aud="${3:?identity_publish_resource_server_binding: aud required}"
  local binding_dir env_path sot_systemd base dropin_path

  binding_dir="$(workload_identity_binding_dir "${wl_name}")"
  mkdir -p "${binding_dir}"
  env_path="${binding_dir}/resource-server.env"
  _identity_write_resource_server_env "${env_path}" "${issuer}" "${aud}" "${wl_name}:api"

  _identity_sync_workload_dropins "${wl_name}"

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${binding_dir}")" 2>/dev/null || true
  fi
}

identity_unpublish_resource_server_binding() {
  local wl_name="${1:?identity_unpublish_resource_server_binding: workload name required}"
  local binding_dir env_path

  binding_dir="$(workload_identity_binding_dir "${wl_name}")"
  env_path="${binding_dir}/resource-server.env"
  rm -f "${env_path}"
  _identity_prune_empty_binding_dir "${wl_name}"
  _identity_sync_workload_dropins "${wl_name}"
}

identity_publish_client_binding() {
  local wl_name="${1:?identity_publish_client_binding: workload name required}"
  local issuer="${2:?identity_publish_client_binding: issuer required}"
  local resource="${3:?identity_publish_client_binding: resource required}"
  local scope="${4:?identity_publish_client_binding: scope required}"
  local callback_urls="${5:?identity_publish_client_binding: callback urls required}"
  local binding_dir env_path

  binding_dir="$(workload_identity_binding_dir "${wl_name}")"
  mkdir -p "${binding_dir}"
  env_path="${binding_dir}/client.env"
  _identity_write_client_env "${env_path}" "${issuer}" "${wl_name}" "${resource}" \
    "${scope}" "${callback_urls}"

  _identity_sync_workload_dropins "${wl_name}"

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${binding_dir}")" 2>/dev/null || true
  fi
}

identity_unpublish_client_binding() {
  local wl_name="${1:?identity_unpublish_client_binding: workload name required}"
  local binding_dir env_path

  binding_dir="$(workload_identity_binding_dir "${wl_name}")"
  env_path="${binding_dir}/client.env"
  rm -f "${env_path}"
  _identity_prune_empty_binding_dir "${wl_name}"
  _identity_sync_workload_dropins "${wl_name}"
}

# Upsert Environment-scoped Pocket ID API; full-replace permissions; return API JSON on stdout.
identity_converge_resource_server() {
  local env_slug="${1:?identity_converge_resource_server: env slug required}"
  local permissions_json="${2:?identity_converge_resource_server: permissions json required}"
  local resource api_name api_json api_id

  resource="$(identity_resource_aud_for_slug "${env_slug}")" || return 1
  api_name="$(identity_resource_api_display_name_for_slug "${env_slug}")" || return 1

  api_json="$(identity_pocket_id_api_find_by_resource "${resource}" || true)"
  if [[ -z "${api_json}" ]]; then
    # /api/apis list may transiently fail while Pocket ID is settling.
    # If we can't find the API yet, attempt create, but treat 409-conflict
    # as "already exists" and re-find until we can proceed.
    for _ in $(seq 1 10); do
      api_json="$(identity_pocket_id_api_find_by_resource "${resource}" || true)" || true
      [[ -n "${api_json}" ]] && break
      sleep 1
    done
  fi

  if [[ -z "${api_json}" ]]; then
    api_json="$(identity_pocket_id_api_create "${api_name}" "${resource}" || true)"
  fi
  if [[ -z "${api_json}" ]]; then
    for _ in $(seq 1 10); do
      api_json="$(identity_pocket_id_api_find_by_resource "${resource}" || true)" || true
      [[ -n "${api_json}" ]] && break
      sleep 1
    done
  fi
  [[ -n "${api_json}" ]] || return 1

  api_id="$(printf '%s\n' "${api_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
    || return 1
  api_json="$(identity_pocket_id_api_update_permissions "${api_id}" "${permissions_json}")" || return 1
  printf '%s\n' "${api_json}"
}

identity_delete_resource_server_if_present() {
  local env_slug="${1:?identity_delete_resource_server_if_present: env slug required}"
  local resource api_json api_id
  resource="$(identity_resource_aud_for_slug "${env_slug}")" || return 1
  api_json="$(identity_pocket_id_api_find_by_resource "${resource}" || true)"
  [[ -n "${api_json}" ]] || return 0
  api_id="$(printf '%s\n' "${api_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
    || return 1
  identity_pocket_id_api_delete "${api_id}" || return 1
  echo "Identity: deleted Environment-scoped resource server ${resource}" >&2
}

# Gather catalog + client claimants; converge Pocket ID; publish/unpublish bindings.
identity_fulfill_declarations() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"
  local env_slug="${2:-${ENV_SLUG-}}"

  if [[ -z "${workloads_root}" ]]; then
    echo "identity_fulfill_declarations: workloads root required" >&2
    return 1
  fi
  if [[ -z "${env_slug}" ]]; then
    env_slug="$(component_handoff_environment_slug)" || return 1
  fi

  command -v python3 >/dev/null || {
    echo "identity_fulfill_declarations: python3 required" >&2
    return 1
  }

  local catalog_declarants_file sorted_catalog_declarants
  local catalog_claimants_file sorted_catalog
  local client_claimants_file sorted_client
  local permissions_json api_json issuer aud resource wl_name claims had_binding
  local callback_urls_json keys_file scope callback_urls_flat wl_dir

  catalog_declarants_file="$(mktemp "${TMPDIR:-/tmp}/identity-catalog-declarants.XXXXXX")"
  sorted_catalog_declarants="$(mktemp "${TMPDIR:-/tmp}/identity-catalog-decl-sorted.XXXXXX")"
  catalog_claimants_file="$(mktemp "${TMPDIR:-/tmp}/identity-catalog-claimants.XXXXXX")"
  sorted_catalog="$(mktemp "${TMPDIR:-/tmp}/identity-catalog-sorted.XXXXXX")"
  client_claimants_file="$(mktemp "${TMPDIR:-/tmp}/identity-client-claimants.XXXXXX")"
  sorted_client="$(mktemp "${TMPDIR:-/tmp}/identity-client-sorted.XXXXXX")"
  : >"${catalog_declarants_file}"
  : >"${catalog_claimants_file}"
  : >"${client_claimants_file}"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if [[ "${wl_name}" == "identity" ]]; then
        rm -f "${catalog_declarants_file}" "${sorted_catalog_declarants}" \
          "${catalog_claimants_file}" "${sorted_catalog}" \
          "${client_claimants_file}" "${sorted_client}"
        echo "Identity gather: Workload basename 'identity' is reserved" >&2
        return 1
      fi
      claims="$(identity_catalog_workload_has_declaration "${wl_dir}")" || {
        rm -f "${catalog_declarants_file}" "${sorted_catalog_declarants}" \
          "${catalog_claimants_file}" "${sorted_catalog}" \
          "${client_claimants_file}" "${sorted_client}"
        return 1
      }
      [[ "${claims}" == "1" ]] && printf '%s\n' "${wl_name}" >>"${catalog_declarants_file}"
      claims="$(identity_catalog_workload_is_run_claimant "${wl_dir}")" || {
        rm -f "${catalog_declarants_file}" "${sorted_catalog_declarants}" \
          "${catalog_claimants_file}" "${sorted_catalog}" \
          "${client_claimants_file}" "${sorted_client}"
        return 1
      }
      [[ "${claims}" == "1" ]] && printf '%s\n' "${wl_name}" >>"${catalog_claimants_file}"
      claims="$(identity_client_workload_is_run_claimant "${wl_dir}")" || {
        rm -f "${catalog_declarants_file}" "${sorted_catalog_declarants}" \
          "${catalog_claimants_file}" "${sorted_catalog}" \
          "${client_claimants_file}" "${sorted_client}"
        return 1
      }
      [[ "${claims}" == "1" ]] && printf '%s\n' "${wl_name}" >>"${client_claimants_file}"
    done
  fi

  LC_ALL=C sort -u "${catalog_declarants_file}" >"${sorted_catalog_declarants}"
  rm -f "${catalog_declarants_file}"
  LC_ALL=C sort -u "${catalog_claimants_file}" >"${sorted_catalog}"
  rm -f "${catalog_claimants_file}"
  LC_ALL=C sort -u "${client_claimants_file}" >"${sorted_client}"
  rm -f "${client_claimants_file}"

  resource="$(identity_resource_aud_for_slug "${env_slug}")" || {
    rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
    return 1
  }

  api_json=""
  issuer=""

  if [[ -s "${sorted_catalog_declarants}" ]]; then
    permissions_json="$(identity_merge_catalog_permissions_json \
      "${sorted_catalog_declarants}" "${workloads_root}")" || {
      rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
      return 1
    }
    api_json="$(identity_converge_resource_server "${env_slug}" "${permissions_json}")" || {
      rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
      return 1
    }
    issuer="$(identity_pocket_id_discovery_issuer)" || {
      rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
      return 1
    }
    aud="${resource}"

    while IFS= read -r wl_name; do
      [[ -n "${wl_name}" ]] || continue
      identity_publish_resource_server_binding "${wl_name}" "${issuer}" "${aud}" || {
        rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
        return 1
      }
      echo "Identity: published resource-server binding for Workload '${wl_name}'" >&2
    done <"${sorted_catalog}"
  fi

  if [[ -s "${sorted_client}" ]]; then
    if [[ -z "${api_json}" ]]; then
      api_json="$(identity_pocket_id_api_find_by_resource "${resource}" || true)"
    fi
    [[ -n "${api_json}" ]] || {
      rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
      echo "Identity gather: OIDC client claimants require Environment-scoped permission catalog" >&2
      return 1
    }
    if [[ -z "${issuer}" ]]; then
      issuer="$(identity_pocket_id_discovery_issuer)" || {
        rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
        return 1
      }
    fi

    while IFS= read -r wl_name; do
      [[ -n "${wl_name}" ]] || continue
      wl_dir="${workloads_root}/${wl_name}"
      callback_urls_json="$(identity_client_callback_urls_json "${wl_dir}")" || {
        rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
        return 1
      }
      identity_converge_oidc_client "${wl_name}" "${callback_urls_json}" || {
        rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
        return 1
      }
      keys_file="$(mktemp "${TMPDIR:-/tmp}/identity-client-keys.XXXXXX")"
      artifact_requires_permission_keys "${wl_dir}/requires.json" >"${keys_file}" || {
        rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}" "${keys_file}"
        return 1
      }
      identity_grant_client_api_access "${wl_name}" "${api_json}" "${keys_file}" || {
        rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}" "${keys_file}"
        return 1
      }
      scope="$(tr '\n' ' ' <"${keys_file}" | sed 's/ $//')"
      callback_urls_flat="$(python3 - "${callback_urls_json}" <<'PY'
import json, sys
print(" ".join(json.loads(sys.argv[1])))
PY
)"
      rm -f "${keys_file}"
      identity_publish_client_binding "${wl_name}" "${issuer}" "${resource}" \
        "${scope}" "${callback_urls_flat}" || {
        rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
        return 1
      }
      echo "Identity: published OIDC client binding for Workload '${wl_name}'" >&2
    done <"${sorted_client}"
  fi

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if grep -Fxq "${wl_name}" "${sorted_catalog}" 2>/dev/null; then
        :
      elif [[ "$(identity_catalog_workload_has_declaration "${wl_dir}")" == "1" ]]; then
        if [[ -f "$(workload_identity_binding_dir "${wl_name}")/resource-server.env" ]]; then
          identity_unpublish_resource_server_binding "${wl_name}" || {
            rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
            return 1
          }
          echo "Identity: unpublished resource-server binding for Workload '${wl_name}' (Intent stop)" >&2
        fi
      elif [[ -f "$(workload_identity_binding_dir "${wl_name}")/resource-server.env" ]]; then
        identity_unpublish_resource_server_binding "${wl_name}" || {
          rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
          return 1
        }
        echo "Identity: unpublished resource-server binding for Workload '${wl_name}'" >&2
      fi

      if grep -Fxq "${wl_name}" "${sorted_client}" 2>/dev/null; then
        continue
      fi
      if [[ "$(identity_client_workload_has_declaration "${wl_dir}")" == "1" ]]; then
        if [[ -f "$(workload_identity_binding_dir "${wl_name}")/client.env" ]]; then
          identity_unpublish_client_binding "${wl_name}" || {
            rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
            return 1
          }
          echo "Identity: unpublished OIDC client binding for Workload '${wl_name}' (Intent stop)" >&2
        fi
        continue
      fi
      if [[ -f "$(workload_identity_binding_dir "${wl_name}")/client.env" ]]; then
        identity_unpublish_client_binding "${wl_name}" || {
          rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
          return 1
        }
        echo "Identity: unpublished OIDC client binding for Workload '${wl_name}'" >&2
      fi
      identity_delete_oidc_client_if_present "${wl_name}" || {
        rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
        return 1
      }
    done
  fi

  rm -f "${sorted_catalog_declarants}" "${sorted_catalog}" "${sorted_client}"
  return 0
}

# post-workloads: prune Pocket ID interior for Orphan-absent basenames; delete the
# Environment-scoped API when no catalog Declarations remain in SoT (#256).
identity_drop_absent_fulfillments() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"
  local env_slug="${2:-${ENV_SLUG-}}"
  local wl_dir wl_name
  local catalog_declarants_file sorted_catalog_declarants permissions_json

  if [[ -z "${workloads_root}" ]]; then
    echo "identity_drop_absent_fulfillments: workloads root required" >&2
    return 1
  fi
  if [[ -z "${env_slug}" ]]; then
    env_slug="$(component_handoff_environment_slug)" || return 1
  fi

  catalog_declarants_file="$(mktemp "${TMPDIR:-/tmp}/identity-catalog-declarants.XXXXXX")"
  sorted_catalog_declarants="$(mktemp "${TMPDIR:-/tmp}/identity-catalog-decl-sorted.XXXXXX")"
  : >"${catalog_declarants_file}"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if [[ "${wl_name}" == "identity" ]]; then
        rm -f "${catalog_declarants_file}" "${sorted_catalog_declarants}"
        echo "Identity gather: Workload basename 'identity' is reserved" >&2
        return 1
      fi
      if [[ "$(identity_catalog_workload_has_declaration "${wl_dir}")" == "1" ]]; then
        printf '%s\n' "${wl_name}" >>"${catalog_declarants_file}"
      fi
    done
  fi
  LC_ALL=C sort -u "${catalog_declarants_file}" >"${sorted_catalog_declarants}"
  rm -f "${catalog_declarants_file}"

  if [[ -s "${sorted_catalog_declarants}" ]]; then
    permissions_json="$(identity_merge_catalog_permissions_json \
      "${sorted_catalog_declarants}" "${workloads_root}")" || {
      rm -f "${sorted_catalog_declarants}"
      return 1
    }
    identity_converge_resource_server "${env_slug}" "${permissions_json}" >/dev/null || {
      rm -f "${sorted_catalog_declarants}"
      return 1
    }
  else
    identity_delete_resource_server_if_present "${env_slug}" || {
      rm -f "${sorted_catalog_declarants}"
      return 1
    }
  fi
  rm -f "${sorted_catalog_declarants}"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if [[ "$(identity_client_workload_has_declaration "${wl_dir}")" != "1" ]]; then
        identity_delete_oidc_client_if_present "${wl_name}" || return 1
      fi
    done
  fi

  if [[ -d "${HOME_DIR}/.config/platform/workloads" ]]; then
    for wl_cfg_dir in "${HOME_DIR}/.config/platform/workloads"/*; do
      [[ -d "${wl_cfg_dir}" ]] || continue
      wl_name="$(basename "${wl_cfg_dir}")"
      if [[ ! -f "${workloads_root}/${wl_name}/manifest.json" ]]; then
        identity_unpublish_resource_server_binding "${wl_name}" || return 1
        identity_unpublish_client_binding "${wl_name}" || return 1
        identity_delete_oidc_client_if_present "${wl_name}" || return 1
        echo "Identity: cleared orphan binding projection for '${wl_name}'" >&2
      fi
    done
  fi
}
