#!/usr/bin/env bash
# Binding contract + full-fulfill rules (ADR-0053 / #199 / #201).
#
# artifact_binding_validate PATH
#   Fail closed on invalid Binding JSON shape.
#
# artifact_binding_environment_remap BINDING REQUIRES
#   Enforce Requires environment full-fulfill (every Requires environment name
#   exactly one remap RHS; Binding remap RHS ⊆ Requires names). Print
#   bag_key=Requires_name one per line, sorted by Requires name.
#
# artifact_binding_environment_select BINDING
#   Binding.environment only (no Requires). Print bag_key=Requires_name one
#   per line, sorted by Requires name. Duplicate remap RHS fails closed.
#
# artifact_binding_fulfill BINDING PROVIDES REQUIRES [WANTLIST]
#   Enforce full fulfill: every Provides route in ≥1 FQDN array; every
#   Requires environment name exactly one remap RHS; Binding route paths ⊆
#   Provides routes; when WANTLIST (FQDNs one per line) is supplied, Binding
#   FQDNs ⊆ that set.

# shellcheck source=provides.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/provides.sh"
# shellcheck source=requires.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/requires.sh"

artifact_binding_validate() {
  local path="${1:?artifact_binding_validate: Binding path required}"
  command -v python3 >/dev/null || {
    echo "artifact_binding_validate: python3 required" >&2
    return 1
  }
  python3 - "${path}" <<'PY'
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    raw = json.load(f)
if not isinstance(raw, dict):
    raise SystemExit(f"Binding must be a JSON object: {path}")

extra = sorted(set(raw) - {"domains", "environment"})
if extra:
    raise SystemExit(
        f"Binding allows only domains/environment in {path}; unexpected: {', '.join(extra)}"
    )

domains = raw.get("domains", {})
if not isinstance(domains, dict):
    raise SystemExit(f"Binding.domains must be an object: {path}")

for fqdn, routes in domains.items():
    if not isinstance(fqdn, str) or fqdn == "":
        raise SystemExit(f"Binding.domains keys must be non-empty FQDNs: {path}")
    if not isinstance(routes, list):
        raise SystemExit(
            f"Binding.domains[{fqdn!r}] must be an array of route paths: {path}"
        )
    for i, route in enumerate(routes):
        if not isinstance(route, str) or route == "":
            raise SystemExit(
                f"Binding.domains[{fqdn!r}][{i}] must be a non-empty route path: {path}"
            )

environment = raw.get("environment", {})
if not isinstance(environment, dict):
    raise SystemExit(f"Binding.environment must be an object: {path}")

for bag_key, req_name in environment.items():
    if not isinstance(bag_key, str) or bag_key == "":
        raise SystemExit(
            f"Binding.environment keys must be non-empty bag keys: {path}"
        )
    if not isinstance(req_name, str) or req_name == "":
        raise SystemExit(
            f"Binding.environment values must be non-empty Requires names: {path}"
        )
PY
}

artifact_binding_environment_remap() {
  local binding="${1:?artifact_binding_environment_remap: Binding path required}"
  local requires="${2:?artifact_binding_environment_remap: Requires path required}"

  artifact_binding_validate "${binding}" || return 1
  artifact_requires_validate "${requires}" || return 1

  python3 - "${binding}" "${requires}" <<'PY'
import json, sys

binding_path, requires_path = sys.argv[1], sys.argv[2]

with open(binding_path, encoding="utf-8") as f:
    binding = json.load(f)
with open(requires_path, encoding="utf-8") as f:
    requires = json.load(f)

requires_env = set((requires.get("environment") or {}).keys())
remap = binding.get("environment") or {}

rhs_counts = {}
rev = {}
for bag_key, req_name in remap.items():
    rhs_counts[req_name] = rhs_counts.get(req_name, 0) + 1
    if req_name not in requires_env:
        raise SystemExit(
            f"Binding.environment[{bag_key!r}] remaps to unknown Requires name {req_name!r}"
        )
    rev[req_name] = bag_key

for name in sorted(requires_env):
    count = rhs_counts.get(name, 0)
    if count != 1:
        raise SystemExit(
            f"Requires environment name {name!r} must appear exactly once as a "
            f"Binding remap RHS (found {count})"
        )
    print(f"{rev[name]}={name}")
PY
}

artifact_binding_environment_select() {
  local binding="${1:?artifact_binding_environment_select: Binding path required}"

  artifact_binding_validate "${binding}" || return 1

  python3 - "${binding}" <<'PY'
import json, sys

binding_path = sys.argv[1]
with open(binding_path, encoding="utf-8") as f:
    binding = json.load(f)

remap = binding.get("environment") or {}
rhs_counts = {}
rev = {}
for bag_key, req_name in remap.items():
    rhs_counts[req_name] = rhs_counts.get(req_name, 0) + 1
    if rhs_counts[req_name] > 1:
        raise SystemExit(
            f"Requires environment name {req_name!r} must appear exactly once as a "
            f"Binding remap RHS (found {rhs_counts[req_name]})"
        )
    rev[req_name] = bag_key

for name in sorted(rev):
    print(f"{rev[name]}={name}")
PY
}

artifact_binding_fulfill() {
  local binding="${1:?artifact_binding_fulfill: Binding path required}"
  local provides="${2:?artifact_binding_fulfill: Provides path required}"
  local requires="${3:?artifact_binding_fulfill: Requires path required}"
  local wantlist="${4-}"

  artifact_provides_validate "${provides}" || return 1
  artifact_binding_environment_remap "${binding}" "${requires}" >/dev/null || return 1

  if [[ -n "${wantlist}" && ! -f "${wantlist}" ]]; then
    echo "artifact_binding_fulfill: want-list file not found: ${wantlist}" >&2
    return 1
  fi

  python3 - "${binding}" "${provides}" "${wantlist}" <<'PY'
import json, sys

binding_path, provides_path, wantlist_path = sys.argv[1:4]

with open(binding_path, encoding="utf-8") as f:
    binding = json.load(f)
with open(provides_path, encoding="utf-8") as f:
    provides = json.load(f)

provides_routes = set((provides.get("routes") or {}).keys())
domains = binding.get("domains") or {}

bound_routes = set()
for fqdn, routes in domains.items():
    for route in routes:
        if route not in provides_routes:
            raise SystemExit(
                f"Binding route {route!r} for {fqdn!r} is not in Provides.routes"
            )
        bound_routes.add(route)

missing_routes = sorted(provides_routes - bound_routes)
if missing_routes:
    raise SystemExit(
        "Binding must attach every Provides route to ≥1 FQDN; unbound: "
        + ", ".join(missing_routes)
    )

if wantlist_path:
    with open(wantlist_path, encoding="utf-8") as f:
        want = {line.strip() for line in f if line.strip()}
    outside = sorted(set(domains) - want)
    if outside:
        raise SystemExit(
            "Binding FQDNs must be ⊆ Domain want-list; outside: " + ", ".join(outside)
        )
PY
}
