#!/usr/bin/env bash
# Database admin credentials resolve/stage helper (ADR-0049 / #188).
# Sourced by ensure-components. Not an operator entrypoint.
#
# Public:
#   database_admin_credentials_dotenv_for ENV_DIR OUTFILE
#     Resolve ROOT_DB_USER / ROOT_DB_PASSWORD from Environment dotenv bag
#     (.env ← .env.override) with shell overriding any key. Fail closed when
#     either is missing or empty. Write Postgres image EnvironmentFile keys
#     POSTGRES_USER / POSTGRES_PASSWORD into OUTFILE (not ROOT_DB_* names —
#     official image contract).

_DB_ADMIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../environment/environment-dotenv.sh
source "${_DB_ADMIN_LIB_DIR}/../environment/environment-dotenv.sh"

database_admin_credentials_dotenv_for() {
  local env_dir="${1:?database_admin_credentials_dotenv_for: Environment dir required}"
  local outfile="${2:?database_admin_credentials_dotenv_for: outfile required}"
  local bag_file
  bag_file="$(mktemp "${TMPDIR:-/tmp}/db-admin-bag.XXXXXX")"

  if ! environment_dotenv_bag "${env_dir}" >"${bag_file}"; then
    rm -f "${bag_file}"
    return 1
  fi

  if ! python3 - "${bag_file}" "${outfile}" <<'PY'
import os
import sys

bag_path, outfile = sys.argv[1], sys.argv[2]
wanted = ("ROOT_DB_USER", "ROOT_DB_PASSWORD")
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
        "Database admin credentials missing (fail closed): " + ", ".join(missing)
    )

os.makedirs(os.path.dirname(outfile) or ".", exist_ok=True)
with open(outfile, "w", encoding="utf-8") as out:
    out.write(f"POSTGRES_USER={resolved['ROOT_DB_USER']}\n")
    out.write(f"POSTGRES_PASSWORD={resolved['ROOT_DB_PASSWORD']}\n")
PY
  then
    rm -f "${bag_file}"
    return 1
  fi
  rm -f "${bag_file}"
  return 0
}
