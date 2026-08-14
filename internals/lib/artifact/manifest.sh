#!/usr/bin/env bash
# Workload Manifest allowlist + required Source (ADR-0053 / #200).
# Sourced by Workload Setup (operator + Host). Validate only.
#
# artifact_manifest_validate PATH
#   Fail closed unless Manifest is a JSON object whose keys are a subset of
#   {intent, description, source}, description is a string when present, and
#   source is required and valid (internal or public zip URI).

# shellcheck source=source.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/source.sh"

artifact_manifest_validate() {
  local manifest="${1:?artifact_manifest_validate: Manifest path required}"
  command -v python3 >/dev/null || {
    echo "artifact_manifest_validate: python3 required" >&2
    return 1
  }
  python3 - "${manifest}" <<'PY' || return 1
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    m = json.load(f)
if not isinstance(m, dict):
    raise SystemExit("manifest must be a JSON object")
allowed = {"intent", "description", "source"}
extra = sorted(set(m) - allowed)
if extra:
    raise SystemExit("manifest unknown keys (ADR-0024 allowlist): " + ", ".join(extra))
if "description" in m and not isinstance(m["description"], str):
    raise SystemExit("manifest.description must be a string when present")
PY
  artifact_source_from_manifest "${manifest}" >/dev/null
}
