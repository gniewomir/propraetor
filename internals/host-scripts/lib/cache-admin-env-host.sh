#!/usr/bin/env bash
# Host install of staged Cache admin EnvironmentFile + ACL (ADR-0055 / #221).
# Sourced by Cache Setup. Expects: ADMIN_ENV, DATA_ROOT (Cache Persist).

cache_install_admin_env() {
  local staged="${1:-}"
  [[ -n "${ADMIN_ENV:-}" ]] || {
    echo "cache_install_admin_env: ADMIN_ENV is unset" >&2
    return 1
  }
  mkdir -p "$(dirname "${ADMIN_ENV}")"
  [[ -n "${staged}" && -f "${staged}" ]] || {
    echo "Cache admin credentials staged EnvironmentFile missing${staged:+ at ${staged}}" >&2
    return 1
  }
  grep -Eq '^CACHE_ADMIN_USER=.+' "${staged}" || {
    echo "Cache admin EnvironmentFile missing CACHE_ADMIN_USER" >&2
    return 1
  }
  grep -Eq '^CACHE_ADMIN_PASSWORD=.+' "${staged}" || {
    echo "Cache admin EnvironmentFile missing CACHE_ADMIN_PASSWORD" >&2
    return 1
  }
  install -m 0600 "${staged}" "${ADMIN_ENV}"
  if [[ -n "${USER_NAME:-}" ]]; then
    chown "${USER_NAME}:${USER_NAME}" "${ADMIN_ENV}" 2>/dev/null || true
  fi
}

# Read CACHE_ADMIN_USER from installed admin EnvironmentFile.
cache_admin_user_from_env() {
  local env_file="${1:?cache_admin_user_from_env: EnvironmentFile required}"
  local line user
  [[ -f "${env_file}" ]] || {
    echo "Cache admin EnvironmentFile missing: ${env_file}" >&2
    return 1
  }
  line="$(grep -E '^CACHE_ADMIN_USER=' "${env_file}" | head -n1)" || true
  user="${line#CACHE_ADMIN_USER=}"
  [[ -n "${user}" ]] || {
    echo "Cache admin EnvironmentFile has empty CACHE_ADMIN_USER" >&2
    return 1
  }
  if [[ "${user}" =~ [[:space:]/] ]]; then
    echo "Cache admin user is not a simple ACL username: '${user}'" >&2
    return 1
  fi
  printf '%s\n' "${user}"
}

# Write Persist ACL file: default off + admin user (SHA-256 hash form).
# Idle standing (#221): no Workload ACL users yet.
# Args: env_file [acl_path]
cache_write_acl_file() {
  local env_file="${1:?cache_write_acl_file: EnvironmentFile required}"
  local acl_path="${2:-${DATA_ROOT}/conf/users.acl}"
  local conf_dir

  [[ -f "${env_file}" ]] || {
    echo "cache_write_acl_file: missing ${env_file}" >&2
    return 1
  }
  [[ -n "${DATA_ROOT:-}" ]] || {
    echo "cache_write_acl_file: DATA_ROOT is unset" >&2
    return 1
  }

  conf_dir="$(dirname "${acl_path}")"
  mkdir -p "${conf_dir}"

  python3 - "${env_file}" "${acl_path}" <<'PY' || return 1
import hashlib
import sys

env_path, acl_path = sys.argv[1], sys.argv[2]
vals = {}
with open(env_path, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line or "=" not in line or line.lstrip().startswith("#"):
            continue
        key, _, val = line.partition("=")
        vals[key] = val
user = vals.get("CACHE_ADMIN_USER", "")
password = vals.get("CACHE_ADMIN_PASSWORD", "")
if not user or not password:
    raise SystemExit("Cache admin EnvironmentFile missing CACHE_ADMIN_USER/PASSWORD")
if any(ch in user for ch in " \t\r\n/\"'\\"):
    raise SystemExit("Cache admin user is not a simple ACL username")
if any(ch in password for ch in " \t\r\n"):
    raise SystemExit("Cache admin password must not contain whitespace")

pw_hash = hashlib.sha256(password.encode("utf-8")).hexdigest()
with open(acl_path, "w", encoding="utf-8") as out:
    out.write("user default off\n")
    out.write(f"user {user} on #{pw_hash} ~* &* +@all\n")
PY

  chmod 0600 "${acl_path}"
  if [[ -n "${USER_NAME:-}" ]]; then
    chown "${USER_NAME}:${USER_NAME}" "${acl_path}" 2>/dev/null || true
  fi
}
