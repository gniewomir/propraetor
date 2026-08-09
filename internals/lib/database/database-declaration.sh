#!/usr/bin/env bash
# Manifest Database Declaration surface (ADR-0049 / #189).
# Pure helper: optional boolean `database` on a Workload Manifest.
#
# database_declaration_claimed MANIFEST
#   Prints `1` when Manifest has `"database": true`, else `0` (omit or false).
#   Fail closed when `database` is present but not a JSON boolean.

database_declaration_claimed() {
  local manifest="${1:?manifest required}"
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
