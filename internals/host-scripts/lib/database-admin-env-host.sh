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
