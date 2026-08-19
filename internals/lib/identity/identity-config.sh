#!/usr/bin/env bash
# Identity issuer hostname contract (ADR-0057 / #251).
# Sourced by ensure-components. Not an operator entrypoint.
#
# Committed file: <environments-root>/<slug>/identity.json
# Shape: { "fqdn": "<want-list FQDN>" } — exactly one issuer FQDN, fail closed otherwise.
#
# Public:
#   identity_config_path SLUG
#     Print absolute path to identity.json for an Environment cloud slug.
#
#   identity_config_validate SLUG
#     Fail closed when identity.json is missing, malformed, or the issuer FQDN
#     is not on the Domain want-list for that Environment.
#
#   identity_config_issuer_fqdn_for SLUG
#     Validate and print the issuer FQDN (one line).
#
#   identity_config_stage_for SLUG OUTFILE
#     Validate then install a copy of identity.json into OUTFILE (0644 content).

_IDENTITY_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../environment/environment.sh
source "${_IDENTITY_CONFIG_LIB_DIR}/../environment/environment.sh"
# shellcheck source=../domains/domains.sh
source "${_IDENTITY_CONFIG_LIB_DIR}/../domains/domains.sh"

identity_config_path() {
  local slug="${1:?identity_config_path: Environment slug required}"
  local env_dir
  env_dir="$(environments_dir_for "${slug}")" || return 1
  printf '%s\n' "${env_dir}/identity.json"
}

identity_config_validate() {
  local slug="${1:?identity_config_validate: Environment slug required}"
  local path want_file
  path="$(identity_config_path "${slug}")" || return 1
  [[ -f "${path}" ]] || {
    echo "identity.json missing for Environment '${slug}' (fail closed): ${path}" >&2
    return 1
  }

  want_file="$(mktemp "${TMPDIR:-/tmp}/identity-want-list.XXXXXX")"
  if ! domains_acme_fqdns_for "${slug}" >"${want_file}"; then
    rm -f "${want_file}"
    return 1
  fi

  if ! python3 - "${path}" "${want_file}" <<'PY'
import json
import sys

path, want_path = sys.argv[1], sys.argv[2]
with open(want_path, encoding="utf-8") as f:
    want = {line.strip() for line in f if line.strip()}

with open(path, encoding="utf-8") as f:
    raw = json.load(f)

if not isinstance(raw, dict):
    raise SystemExit(f"identity.json must be a JSON object: {path}")

extra = sorted(set(raw) - {"fqdn"})
if extra:
    raise SystemExit(
        f"identity.json allows only fqdn in {path}; unexpected: {', '.join(extra)}"
    )
if "fqdn" not in raw:
    raise SystemExit(f"identity.json must declare fqdn in {path}")

fqdn = raw["fqdn"]
if not isinstance(fqdn, str) or fqdn == "":
    raise SystemExit(f"identity.json fqdn must be a non-empty string: {path}")

if fqdn not in want:
    raise SystemExit(
        f"identity.json issuer FQDN not on Domain want-list for this Environment "
        f"(fail closed): {fqdn!r} in {path}"
    )
PY
  then
    rm -f "${want_file}"
    return 1
  fi
  rm -f "${want_file}"
  return 0
}

identity_config_issuer_fqdn_for() {
  local slug="${1:?identity_config_issuer_fqdn_for: Environment slug required}"
  local path
  identity_config_validate "${slug}" || return 1
  path="$(identity_config_path "${slug}")" || return 1
  python3 - "${path}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
print(raw["fqdn"])
PY
}

identity_config_stage_for() {
  local slug="${1:?identity_config_stage_for: Environment slug required}"
  local outfile="${2:?identity_config_stage_for: outfile required}"
  local path
  identity_config_validate "${slug}" || return 1
  path="$(identity_config_path "${slug}")" || return 1
  mkdir -p "$(dirname "${outfile}")"
  install -m 0644 "${path}" "${outfile}"
}
