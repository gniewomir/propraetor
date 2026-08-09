#!/usr/bin/env bash
# Environment Configuration declaration surface (ADR-0035 / #129 / #132).
# Owns Manifest `environment` shape validation and the non-empty →
# quadlets/*.container gate. Sourced by the Environment Configuration module
# (prepare). Operator-side (ADR-0032 / ADR-0041: internals/lib/environment/).
#
# environment_configuration_keys MANIFEST
#   Validates optional Manifest `environment` (omit / [] / non-empty string names).
#   Prints key names one per line (none if omit/[]). Fail closed on bad shape.
#
# environment_configuration_require_containers TREE ACTIVE
#   When ACTIVE=1, fail closed unless TREE/quadlets/*.container exists.

environment_configuration_keys() {
  local manifest="${1:?manifest required}"
  python3 - "${manifest}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    m = json.load(f)
if not isinstance(m, dict):
    raise SystemExit("manifest must be a JSON object")

if "environment" not in m:
    raise SystemExit(0)

env = m["environment"]
if not isinstance(env, list):
    raise SystemExit("manifest.environment must be a JSON array when present")
reserved = ("ROOT_DB_USER", "ROOT_DB_PASSWORD")
for i, item in enumerate(env):
    if not isinstance(item, str) or item == "":
        raise SystemExit(
            "manifest.environment elements must be non-empty strings "
            f"(bad index {i})"
        )
    if item in reserved:
        raise SystemExit(
            f"manifest.environment must not list Database admin credential "
            f"{item} (ADR-0049)"
        )
    print(item)
PY
}

# Fail closed when Manifest lists keys but the Workload tree has no quadlets/*.container.
environment_configuration_require_containers() {
  local tree="${1:?workload tree required}"
  local active="${2:?WL_ENV_ACTIVE required}"
  [[ "${active}" == "1" ]] || return 0
  local found=0
  local f
  if [[ -d "${tree}/quadlets" ]]; then
    for f in "${tree}/quadlets"/*.container; do
      [[ -f "${f}" ]] || continue
      found=1
      break
    done
  fi
  if [[ "${found}" -ne 1 ]]; then
    echo "Environment Configuration requires quadlets/*.container when environment is non-empty" >&2
    return 1
  fi
  return 0
}
