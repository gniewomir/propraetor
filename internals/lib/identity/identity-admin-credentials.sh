#!/usr/bin/env bash
# Identity admin credentials resolve/stage helper (ADR-0057 / #251).
# Sourced by ensure-components. Not an operator entrypoint.
#
# Public:
#   identity_admin_credentials_dotenv_for ENV_DIR ISSUER_FQDN OUTFILE
#     Resolve ROOT_IDENTITY_API_KEY / ROOT_IDENTITY_ENCRYPTION_KEY /
#     ROOT_IDENTITY_ADMIN_EMAIL from Environment dotenv bag (.env ← .env.override)
#     with shell overriding any key. Fail closed when any is missing or invalid.
#     Write Pocket ID / Setup EnvironmentFile keys into OUTFILE (not ROOT_IDENTITY_*
#     names — operator bag keys stay operator-side). APP_URL is derived as
#     https://<issuer FQDN> from identity.json (not operator-supplied).

_IDENTITY_ADMIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../environment/environment-dotenv.sh
source "${_IDENTITY_ADMIN_LIB_DIR}/../environment/environment-dotenv.sh"

identity_admin_credentials_dotenv_for() {
  local env_dir="${1:?identity_admin_credentials_dotenv_for: Environment dir required}"
  local issuer_fqdn="${2:?identity_admin_credentials_dotenv_for: issuer FQDN required}"
  local outfile="${3:?identity_admin_credentials_dotenv_for: outfile required}"
  local bag_file
  bag_file="$(mktemp "${TMPDIR:-/tmp}/identity-admin-bag.XXXXXX")"

  if ! environment_dotenv_bag "${env_dir}" >"${bag_file}"; then
    rm -f "${bag_file}"
    return 1
  fi

  if ! python3 - "${bag_file}" "${outfile}" "${issuer_fqdn}" <<'PY'
import os
import re
import sys

bag_path, outfile, issuer_fqdn = sys.argv[1], sys.argv[2], sys.argv[3]
wanted = (
    "ROOT_IDENTITY_API_KEY",
    "ROOT_IDENTITY_ENCRYPTION_KEY",
    "ROOT_IDENTITY_ADMIN_EMAIL",
)
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
for key in wanted:
    if key in os.environ and os.environ[key] != "":
        resolved[key] = os.environ[key]
    elif key in file_vals and file_vals[key] != "":
        resolved[key] = file_vals[key]
    else:
        missing.append(key)

if missing:
    raise SystemExit(
        "Identity admin credentials missing (fail closed): " + ", ".join(missing)
    )

api_key = resolved["ROOT_IDENTITY_API_KEY"]
encryption_key = resolved["ROOT_IDENTITY_ENCRYPTION_KEY"]
admin_email = resolved["ROOT_IDENTITY_ADMIN_EMAIL"]

if len(api_key) < 16:
    raise SystemExit("ROOT_IDENTITY_API_KEY must be at least 16 characters (fail closed)")
if any(ch in encryption_key for ch in "\r\n"):
    raise SystemExit("ROOT_IDENTITY_ENCRYPTION_KEY must not contain newlines")
if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", admin_email):
    raise SystemExit("ROOT_IDENTITY_ADMIN_EMAIL must look like an email address (fail closed)")

app_url = f"https://{issuer_fqdn}"

os.makedirs(os.path.dirname(outfile) or ".", exist_ok=True)
with open(outfile, "w", encoding="utf-8") as out:
    out.write(f"STATIC_API_KEY={api_key}\n")
    out.write(f"ENCRYPTION_KEY={encryption_key}\n")
    out.write(f"IDENTITY_ADMIN_EMAIL={admin_email}\n")
    out.write(f"APP_URL={app_url}\n")
PY
  then
    rm -f "${bag_file}"
    return 1
  fi
  rm -f "${bag_file}"
  return 0
}
