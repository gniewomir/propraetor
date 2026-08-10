#!/usr/bin/env bash
# Environment ACME configuration helpers (ADR-0045 / ADR-0051).
# Sourced by ensure-components. Requires REPO_ROOT (call-time).
#
# Committed file: <environments-root>/<slug>/acme.json
#   { "directory": "production"|"staging" }
# Contact: Operator Configuration PROPRAETOR_ACME_EMAIL (ADR-0038) when file present.
# Missing file → staging directory, no email line (Host derives contact).

_ACME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../environment/environment.sh
source "${_ACME_LIB_DIR}/../environment/environment.sh"

# Print absolute path to acme.json for an Environment cloud slug.
# Prints nothing and exits 0 when the file is absent.
acme_config_path() {
  local slug="${1-}"
  if [[ -z "${slug}" ]]; then
    echo "FAIL: acme_config_path requires an Environment cloud slug" >&2
    return 1
  fi
  if [[ -z "${REPO_ROOT-}" ]]; then
    echo "FAIL: acme_config_path requires REPO_ROOT" >&2
    return 1
  fi
  local env_dir path
  env_dir="$(environments_dir_for "${slug}")" || return 1
  path="${env_dir}/acme.json"
  if [[ -f "${path}" ]]; then
    printf '%s\n' "${path}"
  fi
  return 0
}

# Print Edge ACME EnvironmentFile dotenv for an Environment cloud slug.
# Missing acme.json → EDGE_ACME_DIRECTORY=staging only.
# Present → require directory-only JSON + PROPRAETOR_ACME_EMAIL; emit both keys.
# Fail closed on bad shape or missing/invalid Operator Configuration contact.
acme_config_dotenv_for() {
  local slug="${1-}"
  if [[ -z "${slug}" ]]; then
    echo "FAIL: acme_config_dotenv_for requires an Environment cloud slug" >&2
    return 1
  fi
  if [[ -z "${REPO_ROOT-}" ]]; then
    echo "FAIL: acme_config_dotenv_for requires REPO_ROOT" >&2
    return 1
  fi
  local path
  path="$(acme_config_path "${slug}")" || return 1
  if [[ -z "${path}" ]]; then
    printf 'EDGE_ACME_DIRECTORY=staging\n'
    return 0
  fi
  local email="${PROPRAETOR_ACME_EMAIL-}"
  if [[ -z "${email}" ]]; then
    echo "FAIL: PROPRAETOR_ACME_EMAIL is required when ${path} is present (Operator Configuration)" >&2
    return 1
  fi
  python3 - "${path}" "${email}" <<'PY'
import json
import sys

path, email = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    raw = json.load(f)
if not isinstance(raw, dict):
    raise SystemExit(f"ACME config must be an object: {path}")

extra = sorted(set(raw) - {"directory"})
if extra:
    raise SystemExit(
        f"ACME config allows only 'directory' in {path}; unexpected: {', '.join(extra)}"
    )

directory = raw.get("directory")
if directory not in ("production", "staging"):
    raise SystemExit(
        f"ACME config 'directory' must be 'production' or 'staging' in {path}"
    )

if not isinstance(email, str) or not email.strip():
    raise SystemExit("PROPRAETOR_ACME_EMAIL must be a non-empty contact address")
email = email.strip()
if any(ch.isspace() for ch in email) or "=" in email:
    raise SystemExit("PROPRAETOR_ACME_EMAIL is not a simple contact address")

print(f"EDGE_ACME_DIRECTORY={directory}")
print(f"EDGE_ACME_EMAIL={email}")
PY
}
