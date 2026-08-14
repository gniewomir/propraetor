#!/usr/bin/env bash
# Environment Configuration declaration surface (ADR-0035 / ADR-0053 / #201).
# Binding remaps bag keys onto Requires environment names. Sourced by the
# Environment Configuration module (prepare). Operator-side
# (ADR-0032 / ADR-0041: internals/lib/environment/).
#
# environment_configuration_remap BINDING REQUIRES
#   Full-fulfill Binding.environment onto Requires.environment. Print
#   bag_key=Requires_name one per line (Requires-name order). Empty Requires
#   environment → no lines. ROOT_DB_* bag keys fail closed (ADR-0049).
#
# environment_configuration_require_containers TREE ACTIVE
#   When ACTIVE=1, fail closed unless TREE/quadlets/*.container exists.

_ENVCFG_DECL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../artifact/binding.sh
source "${_ENVCFG_DECL_DIR}/../artifact/binding.sh"

environment_configuration_remap() {
  local binding="${1:?environment_configuration_remap: Binding path required}"
  local requires="${2:?environment_configuration_remap: Requires path required}"
  local pairs

  [[ -f "${binding}" ]] || {
    echo "Binding missing: ${binding}" >&2
    return 1
  }
  [[ -f "${requires}" ]] || {
    echo "Requires missing: ${requires}" >&2
    return 1
  }

  pairs="$(artifact_binding_environment_remap "${binding}" "${requires}")" || return 1
  python3 - "${pairs}" <<'PY' || return 1
import sys

reserved = ("ROOT_DB_USER", "ROOT_DB_PASSWORD")
for line in sys.argv[1].splitlines():
    if not line or "=" not in line:
        continue
    bag_key, _, req_name = line.partition("=")
    if bag_key in reserved or req_name in reserved:
        name = bag_key if bag_key in reserved else req_name
        raise SystemExit(
            f"Binding must not remap Database admin credential {name} into a "
            "Workload (ADR-0049)"
        )
PY
  if [[ -n "${pairs}" ]]; then
    printf '%s\n' "${pairs}"
  fi
}

# Fail closed when Requires environment is non-empty but the Workload tree
# has no quadlets/*.container.
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
    echo "Environment Configuration requires quadlets/*.container when Requires environment is non-empty" >&2
    return 1
  fi
  return 0
}
