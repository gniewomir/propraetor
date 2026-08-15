#!/usr/bin/env bash
# Workload identity + reserved Component dial basenames (#233).
# Sourced by operator Setup staging and Host apply — one check, both entrypoints.
#
# Public interface:
#   workload_identity_require NAME
#     Fail closed unless NAME is a single non-hidden path segment and not a
#     reserved Component dial basename (database / cache).

workload_identity_require() {
  local wl_name="${1:?workload_identity_require: Workload basename required}"

  if [[ -z "${wl_name}" || "${wl_name}" == "." || "${wl_name}" == ".." ]] ||
    [[ "${wl_name}" == .* ]] ||
    [[ "${wl_name}" == */* ]] ||
    [[ "${wl_name}" =~ [[:space:]] ]]; then
    echo "workload name must be a single non-hidden path segment: '${wl_name}'" >&2
    return 1
  fi
  # Service Network dial name for the Database Component (ADR-0049 / #188).
  if [[ "${wl_name}" == "database" ]]; then
    echo "workload basename 'database' is reserved for the Database Component dial identity" >&2
    return 1
  fi
  # Service Network dial name for the Cache Component (ADR-0055 / #221).
  if [[ "${wl_name}" == "cache" ]]; then
    echo "workload basename 'cache' is reserved for the Cache Component dial identity" >&2
    return 1
  fi
  return 0
}
