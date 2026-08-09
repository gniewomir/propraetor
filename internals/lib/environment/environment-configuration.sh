#!/usr/bin/env bash
# Environment Configuration module for Workload Setup / Purge (ADR-0035 / #132 / #140).
# Sourced by Workload Setup and offline tests — not an operator entrypoint.
#
# Public interface (one outcome chain — install or clear):
#   environment_configuration_stage_for_setup STAGE MANIFEST ENV_DIR TREE REMOTE_ROOT
#     Resolve+gate into STAGE/environment.resolved; sets WL_ENV_ACTIVE and
#     WL_ENV_RESOLVED_REMOTE (under REMOTE_ROOT when active; empty when inactive).
#   environment_configuration_apply_resolved WL_NAME RESOLVED_SRC
#     Host half: empty/unset → clear EnvironmentFile/drop-ins; else install from RESOLVED_SRC.
#   environment_configuration_clear WL_NAME
#     Purge clear path (same Host half as apply_resolved with empty src).
#
# Offline tests exercise stage_for_setup → apply_resolved (REMOTE_ROOT may be the local
# STAGE so WL_ENV_RESOLVED_REMOTE is a local path). prepare / install_host are internals.
# There is no separate materialize public path.

_ENVCFG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=environment-configuration-declaration.sh
source "${_ENVCFG_LIB_DIR}/environment-configuration-declaration.sh"
# shellcheck source=environment-dotenv.sh
source "${_ENVCFG_LIB_DIR}/environment-dotenv.sh"
# shellcheck source=../../host-scripts/lib/workload-environment-host.sh
source "${_ENVCFG_LIB_DIR}/../../host-scripts/lib/workload-environment-host.sh"

# Resolve Manifest environment keys from Environment dotenv bag
# (.env ← .env.override) with shell overrides into OUTFILE.
# Omit/[] → remove OUTFILE, WL_ENV_ACTIVE=0.
# Prints WL_ENV_ACTIVE=0|1 on stdout for the caller to eval.
environment_configuration_resolve() {
  local manifest="${1:?manifest required}"
  local env_dir="${2:?env dir required}"
  local outfile="${3:?outfile required}"
  local keys_file bag_file
  keys_file="$(mktemp "${TMPDIR:-/tmp}/envcfg-keys.XXXXXX")"
  bag_file="$(mktemp "${TMPDIR:-/tmp}/envcfg-bag.XXXXXX")"

  if ! environment_configuration_keys "${manifest}" >"${keys_file}"; then
    rm -f "${keys_file}" "${bag_file}"
    return 1
  fi

  if [[ ! -s "${keys_file}" ]]; then
    rm -f "${keys_file}" "${bag_file}"
    if [[ -e "${outfile}" ]]; then
      rm -f "${outfile}"
    fi
    printf 'WL_ENV_ACTIVE=0\n'
    return 0
  fi

  if ! environment_dotenv_bag "${env_dir}" >"${bag_file}"; then
    rm -f "${keys_file}" "${bag_file}"
    return 1
  fi

  if ! python3 - "${bag_file}" "${outfile}" "${keys_file}" <<'PY'
import os
import sys

bag_path, outfile, keys_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(keys_path, encoding="utf-8") as f:
    keys = [line.rstrip("\n") for line in f if line.rstrip("\n") != ""]

file_vals = {}
with open(bag_path, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line or "=" not in line:
            continue
        key, _, val = line.partition("=")
        file_vals[key] = val

resolved = {}
missing = []
for key in keys:
    if key in os.environ:
        resolved[key] = os.environ[key]
    elif key in file_vals:
        resolved[key] = file_vals[key]
    else:
        missing.append(key)

if missing:
    raise SystemExit(
        "Environment Configuration missing keys (fail closed): " + ", ".join(missing)
    )

os.makedirs(os.path.dirname(outfile) or ".", exist_ok=True)
with open(outfile, "w", encoding="utf-8") as out:
    for key in keys:
        out.write(f"{key}={resolved[key]}\n")

print("WL_ENV_ACTIVE=1")
PY
  then
    rm -f "${keys_file}" "${bag_file}"
    return 1
  fi
  rm -f "${keys_file}" "${bag_file}"
  return 0
}

# Adapter internal: resolve + gate once. Writes OUTFILE when active.
# Prints WL_ENV_ACTIVE=0|1 on stdout for eval.
environment_configuration_prepare() {
  local manifest="${1:?manifest required}"
  local env_dir="${2:?env dir required}"
  local tree="${3:?workload tree required}"
  local outfile="${4:?outfile required}"
  local resolve_out

  resolve_out="$(environment_configuration_resolve "${manifest}" "${env_dir}" "${outfile}")" || return 1
  eval "${resolve_out}"
  environment_configuration_require_containers "${tree}" "${WL_ENV_ACTIVE}" || return 1
  printf '%s\n' "${resolve_out}"
}

# SSH staging adapter for Workload Setup: prepare into STAGE/environment.resolved
# and set WL_ENV_ACTIVE plus WL_ENV_RESOLVED_REMOTE (under REMOTE_ROOT when active).
# No stdout assignment protocol — callers read the globals after a successful return.
environment_configuration_stage_for_setup() {
  local stage="${1:?stage dir required}"
  local manifest="${2:?manifest required}"
  local env_dir="${3:?env dir required}"
  local tree="${4:?workload tree required}"
  local remote_root="${5:?remote stage root required}"
  local outfile="${stage}/environment.resolved"
  local prepare_out

  prepare_out="$(environment_configuration_prepare "${manifest}" "${env_dir}" "${tree}" "${outfile}")" || return 1
  eval "${prepare_out}"
  if [[ "${WL_ENV_ACTIVE}" == "1" ]]; then
    [[ -f "${outfile}" ]] || {
      echo "Environment Configuration resolve produced no file" >&2
      return 1
    }
    # Ambient for Workload Setup Host invoke (read after successful return).
    # shellcheck disable=SC2034  # intentional ambient output of this adapter
    WL_ENV_RESOLVED_REMOTE="${remote_root}/environment.resolved"
  else
    # shellcheck disable=SC2034  # intentional ambient output of this adapter
    WL_ENV_RESOLVED_REMOTE=""
  fi
  return 0
}
