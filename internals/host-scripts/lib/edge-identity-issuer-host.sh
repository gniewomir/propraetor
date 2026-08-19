#!/usr/bin/env bash
# Edge Identity issuer FQDN + route-collision guard (ADR-0057 / #252).
# Sourced by Edge domain-front reconcile and Route gather.
#
# Public:
#   edge_identity_issuer_fqdn_from_handoff
#     Print the issuer FQDN from Component Setup handoff identity.json (one line).
#
#   edge_routes_reject_issuer_collision WORKLOADS_ROOT ISSUER_FQDN
#     Fail closed when any Workload Binding attaches Routes to the issuer FQDN.

_edge_identity_issuer_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=component-handoff-host.sh
source "${_edge_identity_issuer_lib_dir}/component-handoff-host.sh"

edge_identity_issuer_fqdn_from_handoff() {
  local config
  config="$(component_handoff_identity_config)"
  [[ -f "${config}" ]] || {
    echo "edge_identity_issuer_fqdn_from_handoff: Identity config handoff missing at ${config}" >&2
    return 1
  }
  python3 - "${config}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    raw = json.load(f)
if not isinstance(raw, dict):
    raise SystemExit(f"identity.json must be a JSON object: {sys.argv[1]}")
fqdn = raw.get("fqdn")
if not isinstance(fqdn, str) or fqdn == "":
    raise SystemExit(f"identity.json fqdn must be a non-empty string: {sys.argv[1]}")
print(fqdn)
PY
}

edge_routes_reject_issuer_collision() {
  local workloads_root="${1:?edge_routes_reject_issuer_collision: workloads root required}"
  local issuer_fqdn="${2:?edge_routes_reject_issuer_collision: issuer FQDN required}"

  [[ -d "${workloads_root}" ]] || return 0

  python3 - "${workloads_root}" "${issuer_fqdn}" <<'PY'
import json
import os
import sys

workloads_root, issuer_fqdn = sys.argv[1], sys.argv[2]
offenders = []

for entry in sorted(os.listdir(workloads_root)):
    if entry.startswith("."):
        continue
    wl_dir = os.path.join(workloads_root, entry)
    if not os.path.isdir(wl_dir):
        continue
    manifest = os.path.join(wl_dir, "manifest.json")
    binding = os.path.join(wl_dir, "binding.json")
    if not os.path.isfile(manifest) or not os.path.isfile(binding):
        continue
    try:
        with open(manifest, encoding="utf-8") as f:
            manifest_obj = json.load(f)
    except Exception as e:
        raise SystemExit(f"Edge issuer route collision: failed to read {manifest}: {e}")
    if manifest_obj.get("intent") != "run":
        continue
    try:
        with open(binding, encoding="utf-8") as f:
            binding_obj = json.load(f)
    except Exception as e:
        raise SystemExit(f"Edge issuer route collision: failed to read {binding}: {e}")
    domains = binding_obj.get("domains") or {}
    routes = domains.get(issuer_fqdn)
    if routes:
        offenders.append(entry)

if offenders:
    raise SystemExit(
        "Edge fails closed: Workload Binding attaches Routes to Identity issuer FQDN "
        f"{issuer_fqdn!r} (workloads: {', '.join(offenders)})"
    )
PY
}
