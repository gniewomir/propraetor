#!/usr/bin/env bash
# Database admin credentials resolve/stage helper (ADR-0049 / #188).
# Sourced by ensure-components. Not an operator entrypoint.
#
# Public:
#   database_admin_credentials_dotenv_for ENV_DIR OUTFILE
#     Resolve ROOT_DB_USER / ROOT_DB_PASSWORD from ENV_DIR/.env (strict dotenv)
#     with shell overriding any key. Fail closed when either is missing or empty.
#     Write Postgres image EnvironmentFile keys POSTGRES_USER / POSTGRES_PASSWORD
#     into OUTFILE (not ROOT_DB_* names — official image contract).

database_admin_credentials_dotenv_for() {
  local env_dir="${1:?database_admin_credentials_dotenv_for: Environment dir required}"
  local outfile="${2:?database_admin_credentials_dotenv_for: outfile required}"
  local dotenv="${env_dir}/.env"

  python3 - "${dotenv}" "${outfile}" <<'PY'
import os
import re
import sys

dotenv_path, outfile = sys.argv[1], sys.argv[2]
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
wanted = ("ROOT_DB_USER", "ROOT_DB_PASSWORD")
file_vals = {}

if os.path.isfile(dotenv_path):
    with open(dotenv_path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if line.strip() == "" or line.lstrip().startswith("#"):
                continue
            if line.startswith("export ") or line.startswith("export\t"):
                raise SystemExit(
                    f"invalid dotenv at {dotenv_path}:{lineno}: export is not allowed"
                )
            if "=" not in line:
                raise SystemExit(
                    f"invalid dotenv at {dotenv_path}:{lineno}: expected KEY=value"
                )
            key, _, val = line.partition("=")
            if not KEY_RE.match(key):
                raise SystemExit(
                    f"invalid dotenv at {dotenv_path}:{lineno}: bad key name"
                )
            if "\n" in val or "\r" in val:
                raise SystemExit(
                    f"invalid dotenv at {dotenv_path}:{lineno}: multiline values are not allowed"
                )
            if val.startswith("'") and val.endswith("'") and len(val) >= 2:
                raise SystemExit(
                    f"invalid dotenv at {dotenv_path}:{lineno}: single-quoted values are not allowed"
                )
            if val.startswith('"') and val.endswith('"') and len(val) >= 2:
                val = val[1:-1]
            if "${" in val:
                raise SystemExit(
                    f"invalid dotenv at {dotenv_path}:{lineno}: interpolation is not allowed"
                )
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
}
