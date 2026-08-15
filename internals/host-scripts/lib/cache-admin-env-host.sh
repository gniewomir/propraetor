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

# Workload ACL command whitelist (ADR-0055 / spike): type categories + explicit
# keyspace verbs; never +@keyspace (admits SCAN/KEYS/FLUSH*).
# Printed as a single ACL rule fragment after "user <name> on resetpass …".
cache_workload_acl_commands() {
  printf '%s' \
    '-@all +@string +@hash +@list +@set +@sortedset +ping +del +unlink +exists +type +expire +expireat +pexpire +pexpireat +ttl +pttl +persist +touch'
}

# Write Persist ACL file: default off + admin (+ Workload users from Persist clients).
# Intent-run claimants (#222): cert-only `on` (resetpass, ~basename:*, whitelist).
# Non-claimants with durable client material (#224): `off` until Orphan Reap (#225).
# Idle standing (#221): omit claimants_file → every Persist client user is `off`.
# Args: env_file [claimants_file]
cache_write_acl_file() {
  local env_file="${1:?cache_write_acl_file: EnvironmentFile required}"
  local claimants_file="${2:-}"
  local acl_path="${DATA_ROOT}/conf/users.acl"
  local clients_root="${DATA_ROOT}/clients"
  local conf_dir
  local cmds

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
  cmds="$(cache_workload_acl_commands)"

  python3 - "${env_file}" "${acl_path}" "${claimants_file}" "${cmds}" "${clients_root}" <<'PY' || return 1
import hashlib
import os
import sys

env_path, acl_path, claimants_path, cmds, clients_root = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    sys.argv[4],
    sys.argv[5],
)
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

unsafe = set("*?[]:")
claimants = set()
if claimants_path:
    with open(claimants_path, encoding="utf-8") as cf:
        for raw in cf:
            name = raw.rstrip("\n")
            if name:
                claimants.add(name)

retained = []
if os.path.isdir(clients_root):
    for name in sorted(os.listdir(clients_root)):
        client_dir = os.path.join(clients_root, name)
        if not os.path.isdir(client_dir):
            continue
        if not os.path.isfile(os.path.join(client_dir, "client.crt")):
            continue
        retained.append(name)

pw_hash = hashlib.sha256(password.encode("utf-8")).hexdigest()
with open(acl_path, "w", encoding="utf-8") as out:
    out.write("user default off\n")
    out.write(f"user {user} on #{pw_hash} ~* &* +@all\n")
    for name in retained:
        if any(ch in name for ch in unsafe) or any(ch in name for ch in " \t\r\n/\"'\\"):
            raise SystemExit(
                f"Cache ACL: basename is not ACL-safe: {name!r}"
            )
        if name == "cache" or name == user:
            raise SystemExit(
                f"Cache ACL: basename collides with reserved identity: {name!r}"
            )
        if name in claimants:
            out.write(
                f"user {name} on resetpass ~{name}:* resetchannels {cmds}\n"
            )
        else:
            # Intent stop / non-claim: disable identity; Orphan Reap deletes (#225).
            out.write(f"user {name} off\n")
    for name in sorted(claimants - set(retained)):
        # Claimant without Persist client yet (ensure order): still emit on-line;
        # component_tls_ensure_client runs before this write in fulfill.
        if any(ch in name for ch in unsafe) or any(ch in name for ch in " \t\r\n/\"'\\"):
            raise SystemExit(
                f"Cache ACL: basename is not ACL-safe: {name!r}"
            )
        if name == "cache" or name == user:
            raise SystemExit(
                f"Cache ACL: basename collides with reserved identity: {name!r}"
            )
        out.write(
            f"user {name} on resetpass ~{name}:* resetchannels {cmds}\n"
        )
PY

  chmod 0600 "${acl_path}"
  if [[ -n "${USER_NAME:-}" ]]; then
    chown "${USER_NAME}:${USER_NAME}" "${acl_path}" 2>/dev/null || true
  fi
}
