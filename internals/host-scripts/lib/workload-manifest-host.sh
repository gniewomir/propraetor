#!/usr/bin/env bash
# Host Workload Manifest readers (Intent + Database Declaration).
# Sourced by Workload Setup, Edge Route gather, and Database fulfill.
# Single contract for Manifest Intent and optional boolean `database` (ADR-0024 / ADR-0049).

# Print Manifest Intent (run|stop|trash). Fail closed otherwise.
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
if intent not in ("run", "stop", "trash"):
    raise SystemExit("manifest.intent must be run|stop|trash")
print(intent)
PY
}

# Print 1 when Manifest has `"database": true`, else 0 (omit or false).
# Fail closed when `database` is present but not a JSON boolean.
workload_manifest_database_claimed() {
  local manifest="${1:?workload_manifest_database_claimed: Manifest path required}"
  command -v python3 >/dev/null || {
    echo "workload_manifest_database_claimed: python3 required to read Workload Manifest" >&2
    return 1
  }
  python3 - "${manifest}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    m = json.load(f)
if not isinstance(m, dict):
    raise SystemExit("manifest must be a JSON object")
if "database" not in m:
    print("0")
    raise SystemExit(0)
val = m["database"]
if not isinstance(val, bool):
    raise SystemExit("manifest.database must be a boolean when present")
print("1" if val else "0")
PY
}
