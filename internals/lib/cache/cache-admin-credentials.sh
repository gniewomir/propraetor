#!/usr/bin/env bash
# Cache admin credentials resolve/stage helper (ADR-0055 / #221).
# Sourced by ensure-components. Not an operator entrypoint.
#
# Public:
#   cache_admin_credentials_dotenv_for ENV_DIR OUTFILE
#     Resolve ROOT_CACHE_USER / ROOT_CACHE_PASSWORD from Environment dotenv bag
#     (.env ← .env.override) with shell overriding any key. Fail closed when
#     either is missing or empty. Write Persist EnvironmentFile keys
#     CACHE_ADMIN_USER / CACHE_ADMIN_PASSWORD into OUTFILE (not ROOT_CACHE_*
#     names — operator bag keys stay operator-side).

_CACHE_ADMIN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../environment/environment-dotenv.sh
source "${_CACHE_ADMIN_LIB_DIR}/../environment/environment-dotenv.sh"

cache_admin_credentials_dotenv_for() {
  local env_dir="${1:?cache_admin_credentials_dotenv_for: Environment dir required}"
  local outfile="${2:?cache_admin_credentials_dotenv_for: outfile required}"
  local bag_file
  bag_file="$(mktemp "${TMPDIR:-/tmp}/cache-admin-bag.XXXXXX")"

  if ! environment_dotenv_bag "${env_dir}" >"${bag_file}"; then
    rm -f "${bag_file}"
    return 1
  fi

  if ! python3 - "${bag_file}" "${outfile}" <<'PY'
import os
import sys

bag_path, outfile = sys.argv[1], sys.argv[2]
wanted = ("ROOT_CACHE_USER", "ROOT_CACHE_PASSWORD")
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
        "Cache admin credentials missing (fail closed): " + ", ".join(missing)
    )

user = resolved["ROOT_CACHE_USER"]
password = resolved["ROOT_CACHE_PASSWORD"]
if any(ch in user for ch in " \t\r\n/\"'\\"):
    raise SystemExit("Cache admin user is not a simple ACL username")
if any(ch in password for ch in " \t\r\n"):
    raise SystemExit("Cache admin password must not contain whitespace")

os.makedirs(os.path.dirname(outfile) or ".", exist_ok=True)
with open(outfile, "w", encoding="utf-8") as out:
    out.write(f"CACHE_ADMIN_USER={user}\n")
    out.write(f"CACHE_ADMIN_PASSWORD={password}\n")
PY
  then
    rm -f "${bag_file}"
    return 1
  fi
  rm -f "${bag_file}"
  return 0
}
