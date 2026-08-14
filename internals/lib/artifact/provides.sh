#!/usr/bin/env bash
# Provides Declaration + reserved Host destination collision (ADR-0053 / #199).
#
# artifact_reserved_basenames
#   Print reserved Host Workload-root basenames (sorted), one per line.
#
# artifact_provides_validate PATH
#   Fail closed on invalid Provides JSON shape.
#
# artifact_provides_directories PATH
#   Print directory keys (sorted), one per line. Validates first.
#
# artifact_provides_routes PATH
#   Print route paths (sorted), one per line. Validates first.
#
# artifact_provides_reserved_collision DEST PROVIDES
#   Fail closed when applying Provides directories would collide with reserved
#   SoT files already present at DEST (root pull), or when a directories key is
#   itself a reserved basename.

artifact_reserved_basenames() {
  printf '%s\n' binding.json manifest.json provides.json requires.json
}

artifact_provides_validate() {
  local path="${1:?artifact_provides_validate: Provides path required}"
  command -v python3 >/dev/null || {
    echo "artifact_provides_validate: python3 required" >&2
    return 1
  }
  python3 - "${path}" <<'PY'
import json, sys

RESERVED = frozenset(
    ("manifest.json", "binding.json", "provides.json", "requires.json")
)

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    raw = json.load(f)
if not isinstance(raw, dict):
    raise SystemExit(f"Provides must be a JSON object: {path}")

extra = sorted(set(raw) - {"directories", "routes"})
if extra:
    raise SystemExit(
        f"Provides allows only directories/routes in {path}; unexpected: {', '.join(extra)}"
    )

if "directories" in raw:
    directories = raw["directories"]
else:
    directories = {}
if not isinstance(directories, dict):
    raise SystemExit(f"Provides directories must be an object: {path}")

for key, val in directories.items():
    if not isinstance(key, str) or key == "":
        raise SystemExit(f"Provides directories keys must be non-empty strings: {path}")
    base = key.rstrip("/").split("/")[-1] if key not in (".", "./") else key
    if key in RESERVED or base in RESERVED:
        raise SystemExit(
            f"Provides directories must not target reserved basename {base!r}: {path}"
        )
    if isinstance(val, bool):
        raise SystemExit(
            f"Provides directories must not use false; omit instead: {path}"
        )
    if not isinstance(val, str) or val == "":
        raise SystemExit(
            f"Provides directories values must be non-empty strings: {path}"
        )

if "routes" in raw:
    routes = raw["routes"]
else:
    routes = {}
if not isinstance(routes, dict):
    raise SystemExit(f"Provides routes must be an object: {path}")

for key, val in routes.items():
    if not isinstance(key, str) or key == "":
        raise SystemExit(f"Provides routes keys must be non-empty strings: {path}")
    if not isinstance(val, str) or val == "":
        raise SystemExit(
            f"Provides routes values must be non-empty description strings: {path}"
        )
PY
}

artifact_provides_directories() {
  local path="${1:?artifact_provides_directories: Provides path required}"
  artifact_provides_validate "${path}" || return 1
  python3 - "${path}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
directories = raw.get("directories") or {}
for key in sorted(directories):
    print(key)
PY
}

artifact_provides_routes() {
  local path="${1:?artifact_provides_routes: Provides path required}"
  artifact_provides_validate "${path}" || return 1
  python3 - "${path}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
routes = raw.get("routes") or {}
for key in sorted(routes):
    print(key)
PY
}

artifact_provides_reserved_collision() {
  local dest="${1:?artifact_provides_reserved_collision: destination dir required}"
  local provides="${2:?artifact_provides_reserved_collision: Provides path required}"
  artifact_provides_validate "${provides}" || return 1
  command -v python3 >/dev/null || {
    echo "artifact_provides_reserved_collision: python3 required" >&2
    return 1
  }
  python3 - "${dest}" "${provides}" <<'PY'
import json, os, sys

RESERVED = frozenset(
    ("manifest.json", "binding.json", "provides.json", "requires.json")
)

dest, provides_path = sys.argv[1], sys.argv[2]
if not os.path.isdir(dest):
    raise SystemExit(f"destination must be a directory: {dest}")

with open(provides_path, encoding="utf-8") as f:
    raw = json.load(f)
directories = raw.get("directories") or {}

present = sorted(name for name in RESERVED if os.path.lexists(os.path.join(dest, name)))
root_pulls = []
for key in directories:
    normalized = key.rstrip("/") or "."
    if normalized in (".", "./"):
        root_pulls.append(key)

if root_pulls and present:
    raise SystemExit(
        "Provides directories root pull would collide with reserved files already "
        f"at destination {dest}: {', '.join(present)}"
    )

for key in directories:
    base = key.rstrip("/").split("/")[-1] if key not in (".", "./") else ""
    if key in RESERVED or base in RESERVED:
        raise SystemExit(
            f"Provides directories key {key!r} collides with reserved basename at {dest}"
        )
PY
}
