#!/usr/bin/env bash
# Requires Declaration contract (ADR-0053 / ADR-0055 / #220).
#
# artifact_requires_validate PATH
#   Fail closed on invalid Requires JSON:
#     required boolean database and cache;
#     optional environment name → description map;
#     optional identity boolean and optional client permissions map.
#
# artifact_requires_environment PATH
#   Print Requires environment names (sorted), one per line.
#
# artifact_requires_database PATH
#   Print 1 when database is true, else 0.
#
# artifact_requires_cache PATH
#   Print 1 when cache is true, else 0.
#
# artifact_requires_identity PATH
#   Print 1 when identity is true, else 0.
#
# artifact_requires_has_permissions PATH
#   Print 1 when permissions map is non-empty, else 0.
#
# artifact_requires_permission_keys PATH
#   Print sorted Requires.permissions keys, one per line.

artifact_requires_validate() {
  local path="${1:?artifact_requires_validate: Requires path required}"
  command -v python3 >/dev/null || {
    echo "artifact_requires_validate: python3 required" >&2
    return 1
  }
  python3 - "${path}" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    raw = json.load(f)
if not isinstance(raw, dict):
    raise SystemExit(f"Requires must be a JSON object: {path}")

allowed = {"environment", "database", "cache", "identity", "permissions"}
extra = sorted(set(raw) - allowed)
if extra:
    raise SystemExit(
        f"Requires allows only environment/database/cache/identity/permissions in {path}; unexpected: {', '.join(extra)}"
    )

if "database" not in raw:
    raise SystemExit(f"Requires.database is required: {path}")
if not isinstance(raw["database"], bool):
    raise SystemExit(f"Requires.database must be a JSON boolean: {path}")

if "cache" not in raw:
    raise SystemExit(f"Requires.cache is required: {path}")
if not isinstance(raw["cache"], bool):
    raise SystemExit(f"Requires.cache must be a JSON boolean: {path}")

if "identity" in raw:
    if not isinstance(raw["identity"], bool):
        raise SystemExit(f"Requires.identity must be a JSON boolean: {path}")

if "permissions" in raw:
    permissions = raw["permissions"]
    if not isinstance(permissions, dict):
        raise SystemExit(f"Requires.permissions must be an object: {path}")
    for key, val in permissions.items():
        if not isinstance(key, str) or key == "":
            raise SystemExit(f"Requires.permissions keys must be non-empty strings: {path}")
        if not isinstance(val, str) or val == "":
            raise SystemExit(
                f"Requires.permissions values must be non-empty description strings: {path}"
            )

environment = raw.get("environment", {})
if "environment" in raw and not isinstance(environment, dict):
    raise SystemExit(f"Requires.environment must be an object: {path}")
if not isinstance(environment, dict):
    raise SystemExit(f"Requires.environment must be an object: {path}")

for key, val in environment.items():
    if not isinstance(key, str) or key == "":
        raise SystemExit(
            f"Requires.environment keys must be non-empty strings: {path}"
        )
    if not isinstance(val, str) or val == "":
        raise SystemExit(
            f"Requires.environment values must be non-empty description strings: {path}"
        )
PY
}

artifact_requires_environment() {
  local path="${1:?artifact_requires_environment: Requires path required}"
  artifact_requires_validate "${path}" || return 1
  python3 - "${path}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
environment = raw.get("environment") or {}
for key in sorted(environment):
    print(key)
PY
}

artifact_requires_database() {
  local path="${1:?artifact_requires_database: Requires path required}"
  artifact_requires_validate "${path}" || return 1
  python3 - "${path}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
print("1" if raw["database"] else "0")
PY
}

artifact_requires_cache() {
  local path="${1:?artifact_requires_cache: Requires path required}"
  artifact_requires_validate "${path}" || return 1
  python3 - "${path}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
print("1" if raw["cache"] else "0")
PY
}

artifact_requires_identity() {
  local path="${1:?artifact_requires_identity: Requires path required}"
  artifact_requires_validate "${path}" || return 1
  python3 - "${path}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
print("1" if raw.get("identity") is True else "0")
PY
}

artifact_requires_has_permissions() {
  local path="${1:?artifact_requires_has_permissions: Requires path required}"
  artifact_requires_validate "${path}" || return 1
  python3 - "${path}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
perms = raw.get("permissions") or {}
print("1" if isinstance(perms, dict) and len(perms) > 0 else "0")
PY
}

artifact_requires_permission_keys() {
  local path="${1:?artifact_requires_permission_keys: Requires path required}"
  artifact_requires_validate "${path}" || return 1
  python3 - "${path}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
perms = raw.get("permissions") or {}
if not isinstance(perms, dict) or not perms:
    raise SystemExit(f"Requires.permissions missing or empty: {sys.argv[1]}")
for key in sorted(perms):
    print(key)
PY
}
