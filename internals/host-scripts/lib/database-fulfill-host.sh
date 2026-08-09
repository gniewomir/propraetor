#!/usr/bin/env bash
# Database Declaration gather + fulfill (ADR-0049 / #189 / #190).
# Intent-run + Manifest database:true → role/db/client cert + published binding.
# Intent stop/trash (non-claimants) → unpublish binding; retain role/db/clients until Purge.
# Sourced by Database Setup. Expects ambient after database_setup begin:
#   DATA_ROOT, CLIENTS_DIR, ADMIN_ENV, HOME_DIR, UNIT_DIR, USER_NAME, WORKLOADS_ROOT
# Requires: quadlet_user, database_tls_ensure_client, database_write_pg_ident_file,
#           database_admin_user_from_env.

# Platform User path for one Workload's published Database binding directory.
workload_database_binding_dir() {
  local wl_name="${1:?workload name required}"
  printf '%s/.config/platform/workloads/%s/database\n' "${HOME_DIR}" "${wl_name}"
}

workload_database_dropin_path() {
  local container_base="${1:?container basename required}"
  printf '%s/%s.d/50-platform-database.conf\n' "${UNIT_DIR}" "${container_base}"
}

# Read Manifest Intent. Prints run|stop|trash; fails closed otherwise.
_database_read_workload_intent() {
  local manifest="$1"
  python3 - "${manifest}" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(m, dict):
    raise SystemExit("manifest must be a JSON object")
intent = m.get("intent")
if intent not in ("run", "stop", "trash"):
    raise SystemExit("manifest.intent must be run|stop|trash")
print(intent)
PY
}

# Print 1 if Manifest claims database:true, else 0. Fail closed on bad type.
# Same contract as internals/lib/database/database-declaration.sh (Host copy —
# operator lib is not staged onto the Host Volume).
_database_manifest_claims() {
  local manifest="$1"
  python3 - "${manifest}" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(m, dict):
    raise SystemExit("manifest must be a JSON object")
if "database" not in m:
    print("0")
    raise SystemExit(0)
val = m["database"]
if not isinstance(val, bool):
    raise SystemExit("manifest.database must be a boolean when present")
print("1" if val else "0")
PY
}

# Create-if-missing role + database named by basename (owner = role).
# Basename is a Workload identity (single path segment); quoted as a PG identifier.
database_ensure_role_and_db() {
  local basename="${1:?database_ensure_role_and_db: basename required}"
  local admin_user
  local role_exists db_exists
  admin_user="$(database_admin_user_from_env "${ADMIN_ENV}")" || return 1

  role_exists="$(
    quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec database-postgres \
        psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -tAc \
        $(printf '%q' "SELECT 1 FROM pg_roles WHERE rolname = '${basename}'")" \
      2>/dev/null | tr -d '[:space:]' || true
  )"
  if [[ "${role_exists}" != "1" ]]; then
    quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec database-postgres \
        psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
        $(printf '%q' "CREATE ROLE \"${basename}\" LOGIN")" \
      || return 1
  fi

  db_exists="$(
    quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec database-postgres \
        psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -tAc \
        $(printf '%q' "SELECT 1 FROM pg_database WHERE datname = '${basename}'")" \
      2>/dev/null | tr -d '[:space:]' || true
  )"
  if [[ "${db_exists}" != "1" ]]; then
    quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec database-postgres \
        psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
        $(printf '%q' "CREATE DATABASE \"${basename}\" OWNER \"${basename}\"")" \
      || return 1
  fi

  # No cross-Workload grants (ADR-0049 / #190): Postgres defaults CONNECT to PUBLIC.
  quadlet_user env "HOME=${HOME_DIR}" bash -c \
    "cd \"\$HOME\" && podman exec database-postgres \
      psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
      $(printf '%q' "REVOKE CONNECT ON DATABASE \"${basename}\" FROM PUBLIC")" \
    || return 1
}

# Publish binding + Setup-owned Quadlet drop-in for one Workload.
database_publish_binding() {
  local wl_name="${1:?database_publish_binding: workload name required}"
  local binding_dir client_dir ca_crt client_crt client_key env_path
  local sot_quadlets base dropin_path mount_root

  client_dir="${DATA_ROOT}/clients/${wl_name}"
  ca_crt="${DATA_ROOT}/ca/ca.crt"
  client_crt="${client_dir}/client.crt"
  client_key="${client_dir}/client.key"
  [[ -f "${ca_crt}" && -f "${client_crt}" && -f "${client_key}" ]] || {
    echo "Database publish: client material missing for '${wl_name}'" >&2
    return 1
  }

  binding_dir="$(workload_database_binding_dir "${wl_name}")"
  mkdir -p "${binding_dir}"
  install -m 0644 "${ca_crt}" "${binding_dir}/ca.crt"
  install -m 0644 "${client_crt}" "${binding_dir}/client.crt"
  install -m 0600 "${client_key}" "${binding_dir}/client.key"

  mount_root=/etc/platform-database
  env_path="${binding_dir}/environment"
  cat >"${env_path}" <<EOF
PGHOST=database
PGPORT=5432
PGUSER=${wl_name}
PGDATABASE=${wl_name}
PGSSLMODE=verify-full
PGSSLROOTCERT=${mount_root}/ca.crt
PGSSLCERT=${mount_root}/client.crt
PGSSLKEY=${mount_root}/client.key
EOF
  chmod 0600 "${env_path}"

  sot_quadlets="${WORKLOADS_ROOT}/${wl_name}/quadlets"
  if [[ -d "${sot_quadlets}" ]]; then
    for base in "${sot_quadlets}"/*.container; do
      [[ -f "${base}" ]] || continue
      base="$(basename "${base}")"
      dropin_path="$(workload_database_dropin_path "${base}")"
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

# Clear published binding + Setup-owned drop-ins for one Workload (Intent stop/trash).
# Retains Host Volume client material, role, and database until Purge (#191).
database_unpublish_binding() {
  local wl_name="${1:?database_unpublish_binding: workload name required}"
  local binding_dir sot_quadlets base dropin_path dropin_dir

  binding_dir="$(workload_database_binding_dir "${wl_name}")"
  rm -rf "${binding_dir}"

  sot_quadlets="${WORKLOADS_ROOT}/${wl_name}/quadlets"
  if [[ -d "${sot_quadlets}" ]]; then
    for base in "${sot_quadlets}"/*.container; do
      [[ -f "${base}" ]] || continue
      base="$(basename "${base}")"
      dropin_path="$(workload_database_dropin_path "${base}")"
      rm -f "${dropin_path}"
      dropin_dir="$(dirname "${dropin_path}")"
      if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
        rmdir "${dropin_dir}" 2>/dev/null || true
      fi
    done
  fi
}

# Reload Postgres config after pg_ident changes (bind-mounted conf).
database_reload_conf() {
  local admin_user
  admin_user="$(database_admin_user_from_env "${ADMIN_ENV}")" || return 1
  quadlet_user env "HOME=${HOME_DIR}" bash -c \
    "cd \"\$HOME\" && podman exec database-postgres \
      psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
      'SELECT pg_reload_conf();'" \
    >/dev/null || {
    echo "Database: pg_reload_conf failed" >&2
    return 1
  }
}

# True if basename is listed in the sorted claimants file.
_database_is_claimant() {
  local wl_name="$1"
  local claimants_file="$2"
  grep -Fxq "${wl_name}" "${claimants_file}" 2>/dev/null
}

# Gather Intent-run database:true claimants from Workload SoT; fulfill create/publish.
# Non-claimants (Intent stop/trash or database false/omit): unpublish binding only;
# role/database/client material retained until Purge (#190 / #191).
database_fulfill_declarations() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"
  local wl_dir wl_name intent claims
  local claimants_file sorted_file
  local had_binding
  local IFS

  if [[ -z "${workloads_root}" ]]; then
    echo "database_fulfill_declarations: workloads root required" >&2
    return 1
  fi

  command -v python3 >/dev/null || {
    echo "database_fulfill_declarations: python3 required" >&2
    return 1
  }

  claimants_file="$(mktemp "${TMPDIR:-/tmp}/platform-db-claimants.XXXXXX")"
  sorted_file="$(mktemp "${TMPDIR:-/tmp}/platform-db-claimants-sorted.XXXXXX")"
  : >"${claimants_file}"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if [[ "${wl_name}" == "database" ]]; then
        rm -f "${claimants_file}" "${sorted_file}"
        echo "Database gather: Workload basename 'database' is reserved" >&2
        return 1
      fi
      intent="$(_database_read_workload_intent "${wl_dir}/manifest.json")" || {
        rm -f "${claimants_file}" "${sorted_file}"
        return 1
      }
      [[ "${intent}" == "run" ]] || continue
      claims="$(_database_manifest_claims "${wl_dir}/manifest.json")" || {
        rm -f "${claimants_file}" "${sorted_file}"
        return 1
      }
      [[ "${claims}" == "1" ]] || continue
      printf '%s\n' "${wl_name}" >>"${claimants_file}"
    done
  fi

  LC_ALL=C sort -u "${claimants_file}" >"${sorted_file}"
  rm -f "${claimants_file}"

  database_write_pg_ident_file "${sorted_file}" || {
    rm -f "${sorted_file}"
    return 1
  }
  database_reload_conf || {
    rm -f "${sorted_file}"
    return 1
  }

  while IFS= read -r wl_name; do
    [[ -n "${wl_name}" ]] || continue
    database_tls_ensure_client "${wl_name}" || {
      rm -f "${sorted_file}"
      return 1
    }
    database_ensure_role_and_db "${wl_name}" || {
      rm -f "${sorted_file}"
      return 1
    }
    database_publish_binding "${wl_name}" || {
      rm -f "${sorted_file}"
      return 1
    }
    echo "Database: fulfilled binding for Workload '${wl_name}'" >&2
  done <"${sorted_file}"

  # Unpublish Workloads present in SoT that are not Intent-run claimants.
  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      if _database_is_claimant "${wl_name}" "${sorted_file}"; then
        continue
      fi
      had_binding=0
      if [[ -d "$(workload_database_binding_dir "${wl_name}")" ]]; then
        had_binding=1
      fi
      # Always run unpublish so orphaned drop-ins clear even if the binding dir is gone.
      database_unpublish_binding "${wl_name}" || {
        rm -f "${sorted_file}"
        return 1
      }
      if [[ "${had_binding}" -eq 1 ]]; then
        echo "Database: unpublished binding for Workload '${wl_name}'" >&2
      fi
    done
  fi

  rm -f "${sorted_file}"
  return 0
}
