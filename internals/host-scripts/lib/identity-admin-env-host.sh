#!/usr/bin/env bash
# Host install of staged Identity admin EnvironmentFile (ADR-0057 / #251).
# Sourced by Identity Setup (future). Expects: ADMIN_ENV (path under Identity interior).

identity_install_admin_env() {
  local staged="${1:-}"
  [[ -n "${ADMIN_ENV:-}" ]] || {
    echo "identity_install_admin_env: ADMIN_ENV is unset" >&2
    return 1
  }
  mkdir -p "$(dirname "${ADMIN_ENV}")"
  [[ -n "${staged}" && -f "${staged}" ]] || {
    echo "Identity admin credentials staged EnvironmentFile missing${staged:+ at ${staged}}" >&2
    return 1
  }
  grep -Eq '^STATIC_API_KEY=.+' "${staged}" || {
    echo "Identity admin EnvironmentFile missing STATIC_API_KEY" >&2
    return 1
  }
  grep -Eq '^ENCRYPTION_KEY=.+' "${staged}" || {
    echo "Identity admin EnvironmentFile missing ENCRYPTION_KEY" >&2
    return 1
  }
  grep -Eq '^IDENTITY_ADMIN_EMAIL=.+' "${staged}" || {
    echo "Identity admin EnvironmentFile missing IDENTITY_ADMIN_EMAIL" >&2
    return 1
  }
  grep -Eq '^APP_URL=https://.+' "${staged}" || {
    echo "Identity admin EnvironmentFile missing APP_URL" >&2
    return 1
  }
  install -m 0600 "${staged}" "${ADMIN_ENV}"
  if [[ -n "${USER_NAME:-}" ]]; then
    chown "${USER_NAME}:${USER_NAME}" "${ADMIN_ENV}" 2>/dev/null || true
  fi
}
