#!/usr/bin/env bash
# Host Workload Manifest Intent reader.
# Sourced by Workload Setup, Edge Route gather, and Database fulfill.
# Manifest allowlist + Source live in internals/lib/artifact/manifest.sh (ADR-0053 / #200).
# Database claim is Requires `database` (ADR-0053 / #202) — not this module.

# Print Manifest Intent (run|stop). Fail closed otherwise.
workload_manifest_intent() {
  local manifest="${1:?workload_manifest_intent: Manifest path required}"
  command -v python3 >/dev/null || {
    echo "workload_manifest_intent: python3 required to read Workload Manifest" >&2
    return 1
  }
  python3 - "${manifest}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    m = json.load(f)
if not isinstance(m, dict):
    raise SystemExit("manifest must be a JSON object")
intent = m.get("intent")
if intent not in ("run", "stop"):
    raise SystemExit("manifest.intent must be run|stop")
print(intent)
PY
}
