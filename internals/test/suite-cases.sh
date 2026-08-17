#!/usr/bin/env bash
# Ordered-suite case inventory (ADR-0056): list, resolve token, slice --from.
# Sourced by Acceptance and Lifecycle runners. Bash 3.2-safe.
# Basename shape: NNNN-short-name.sh (exactly four digits, unique numeric prefix).

suite_cases_numeric_prefix() {
  local base
  base="$(basename "${1:?suite_cases_numeric_prefix: path required}")"
  if [[ "${base}" =~ ^([0-9]{4})- ]]; then
    printf '%s\n' "$((10#${BASH_REMATCH[1]}))"
    return 0
  fi
  return 1
}

# Print sorted case paths in dir (maxdepth 1, [0-9]*.sh). Fail closed on empty,
# non-NNNN- basename, or duplicate numeric prefixes.
suite_cases_list() {
  local dir="${1:?suite_cases_list: directory required}"
  local case_path base key
  local -a paths=()
  local -a keys=()
  while IFS= read -r case_path; do
    [[ -n "${case_path}" ]] || continue
    paths+=("${case_path}")
  done < <(find "${dir}" -maxdepth 1 -type f -name '[0-9]*.sh' | LC_ALL=C sort)

  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "FAIL: no numeric-prefixed cases in ${dir}" >&2
    return 1
  fi

  local i j
  i=0
  while [[ "${i}" -lt ${#paths[@]} ]]; do
    case_path="${paths[i]}"
    base="$(basename "${case_path}")"
    if [[ ! "${base}" =~ ^[0-9]{4}- ]]; then
      echo "FAIL: case '${base}' must be NNNN-short-name.sh (four-digit prefix)" >&2
      return 1
    fi
    key="$(suite_cases_numeric_prefix "${case_path}")" || return 1
    j=0
    while [[ "${j}" -lt ${#keys[@]} ]]; do
      if [[ "${keys[j]}" == "${key}" ]]; then
        echo "FAIL: duplicate numeric prefix ${key} (${base})" >&2
        return 1
      fi
      j=$((j + 1))
    done
    keys+=("${key}")
    i=$((i + 1))
  done

  i=0
  while [[ "${i}" -lt ${#paths[@]} ]]; do
    printf '%s\n' "${paths[i]}"
    i=$((i + 1))
  done
}

# Resolve token to exactly one path among the remaining args (ordered list).
# All-digits: numeric prefix equality (100 == 0100). Else unique basename substring.
suite_cases_resolve() {
  local token="${1-}"
  shift || true
  if [[ -z "${token}" ]]; then
    echo "FAIL: case token required" >&2
    return 1
  fi
  if [[ $# -eq 0 ]]; then
    echo "FAIL: no cases to resolve '${token}' against" >&2
    return 1
  fi

  local -a matched=()
  local case_path base want got
  if [[ "${token}" =~ ^[0-9]+$ ]]; then
    want="$((10#${token}))"
    for case_path in "$@"; do
      got="$(suite_cases_numeric_prefix "${case_path}")" || continue
      if [[ "${got}" -eq "${want}" ]]; then
        matched+=("${case_path}")
      fi
    done
  else
    for case_path in "$@"; do
      base="$(basename "${case_path}")"
      if [[ "${base}" == *"${token}"* ]]; then
        matched+=("${case_path}")
      fi
    done
  fi

  if [[ ${#matched[@]} -eq 0 ]]; then
    echo "FAIL: no case matches token: ${token}" >&2
    return 1
  fi
  if [[ ${#matched[@]} -ne 1 ]]; then
    local listed=""
    for case_path in "${matched[@]}"; do
      listed+=" $(basename "${case_path}")"
    done
    echo "FAIL: token ${token} matched multiple cases:${listed}" >&2
    return 1
  fi
  printf '%s\n' "${matched[0]}"
}

# Print start_path and every later path in the remaining args (inclusive remainder).
suite_cases_from() {
  local start="${1-}"
  shift || true
  if [[ -z "${start}" ]]; then
    echo "FAIL: --from start path required" >&2
    return 1
  fi
  local case_path seen=0
  for case_path in "$@"; do
    if [[ "${seen}" -eq 0 && "${case_path}" == "${start}" ]]; then
      seen=1
    fi
    if [[ "${seen}" -eq 1 ]]; then
      printf '%s\n' "${case_path}"
    fi
  done
  if [[ "${seen}" -eq 0 ]]; then
    echo "FAIL: --from start is not in the suite list: $(basename "${start}")" >&2
    return 1
  fi
}
