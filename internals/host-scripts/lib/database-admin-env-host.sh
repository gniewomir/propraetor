#!/usr/bin/env bash
# Host install of staged Database admin EnvironmentFile (ADR-0049 / #188).
# Sourced by Database Setup. Expects: ADMIN_ENV (path under Database interior).

database_install_admin_env() {
  local staged="${1:-}"
  [[ -n "${ADMIN_ENV:-}" ]] || {
    echo "database_install_admin_env: ADMIN_ENV is unset" >&2
    return 1
  }
  mkdir -p "$(dirname "${ADMIN_ENV}")"
  [[ -n "${staged}" && -f "${staged}" ]] || {
    echo "Database admin credentials staged EnvironmentFile missing${staged:+ at ${staged}}" >&2
    return 1
  }
  # Fail closed if stage lacks Postgres image keys (ensure-components contract).
  grep -Eq '^POSTGRES_USER=.+' "${staged}" || {
    echo "Database admin EnvironmentFile missing POSTGRES_USER" >&2
    return 1
  }
  grep -Eq '^POSTGRES_PASSWORD=.+' "${staged}" || {
    echo "Database admin EnvironmentFile missing POSTGRES_PASSWORD" >&2
    return 1
  }
  install -m 0600 "${staged}" "${ADMIN_ENV}"
  if [[ -n "${USER_NAME:-}" ]]; then
    chown "${USER_NAME}:${USER_NAME}" "${ADMIN_ENV}" 2>/dev/null || true
  fi
}

# Read POSTGRES_USER from installed admin EnvironmentFile (for pg_hba templating).
database_admin_user_from_env() {
  local env_file="${1:?database_admin_user_from_env: EnvironmentFile required}"
  local line user
  [[ -f "${env_file}" ]] || {
    echo "Database admin EnvironmentFile missing: ${env_file}" >&2
    return 1
  }
  line="$(grep -E '^POSTGRES_USER=' "${env_file}" | head -n1)" || true
  user="${line#POSTGRES_USER=}"
  [[ -n "${user}" ]] || {
    echo "Database admin EnvironmentFile has empty POSTGRES_USER" >&2
    return 1
  }
  # pg_hba role token: reject whitespace / path-ish junk.
  if [[ "${user}" =~ [[:space:]/] ]]; then
    echo "Database admin user is not a simple role name: '${user}'" >&2
    return 1
  fi
  printf '%s\n' "${user}"
}

# Keep live SCRAM password aligned with staged admin EnvironmentFile.
# Official image applies POSTGRES_PASSWORD only at first initdb; Setup re-syncs
# so operator database.sh / Environment credentials stay authoritative (#192).
# Uses local trust inside the container (pg_hba local). Does not print secrets.
database_sync_admin_password() {
  local env_file="${1:?database_sync_admin_password: EnvironmentFile required}"
  local sql

  [[ -f "${env_file}" ]] || {
    echo "database_sync_admin_password: missing ${env_file}" >&2
    return 1
  }

  sql="$(
    python3 - "${env_file}" <<'PY'
import sys

path = sys.argv[1]
vals = {}
with open(path, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line or "=" not in line or line.lstrip().startswith("#"):
            continue
        key, _, val = line.partition("=")
        vals[key] = val
user = vals.get("POSTGRES_USER", "")
password = vals.get("POSTGRES_PASSWORD", "")
if not user or not password:
    raise SystemExit("Database admin EnvironmentFile missing POSTGRES_USER/PASSWORD")
if any(ch in user for ch in " \t\r\n/\"'\\"):
    raise SystemExit("Database admin user is not a simple role name")

def lit(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"

# Identifiers: simple role names only (validated above).
print(user)
print(f"ALTER ROLE {user} WITH PASSWORD {lit(password)};")
PY
  )" || return 1

  local admin_user
  admin_user="$(printf '%s\n' "${sql}" | head -n1)"
  sql="$(printf '%s\n' "${sql}" | tail -n +2)"

  quadlet_user env "HOME=${HOME_DIR}" bash -c \
    "cd \"\$HOME\" && podman exec -i database-postgres \
      psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -f -" \
    <<<"${sql}" >/dev/null || {
    echo "Database: failed to sync admin SCRAM password from staged credentials" >&2
    return 1
  }
}
