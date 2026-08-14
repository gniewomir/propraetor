#!/usr/bin/env bash
# Workload Source contract (ADR-0053 / #199).
# Sourced by later Mirror / Manifest readers. Validate only — no fetch.
#
# artifact_source_validate VALUE
#   Print VALUE when it is exactly "internal" or a public http(s) zip URI.
#   Fail closed otherwise.
#
# artifact_source_from_manifest MANIFEST
#   Read Manifest `source` and validate via artifact_source_validate.

artifact_source_validate() {
  local value="${1-}"
  command -v python3 >/dev/null || {
    echo "artifact_source_validate: python3 required" >&2
    return 1
  }
  python3 -c '
import sys
from urllib.parse import urlparse

value = sys.argv[1]
if value == "internal":
    print(value)
    raise SystemExit(0)
if not isinstance(value, str) or not value:
    raise SystemExit("Source must be \"internal\" or a public zip URI")

parsed = urlparse(value)
if parsed.scheme not in ("http", "https") or not parsed.netloc:
    raise SystemExit("Source URI must be http(s) with a host")
path = parsed.path or ""
if not path.lower().endswith(".zip"):
    raise SystemExit("Source URI path must end with .zip")
print(value)
' "${value}"
}

artifact_source_from_manifest() {
  local manifest="${1:?artifact_source_from_manifest: Manifest path required}"
  command -v python3 >/dev/null || {
    echo "artifact_source_from_manifest: python3 required" >&2
    return 1
  }
  local source
  source="$(
    python3 - "${manifest}" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    m = json.load(f)
if not isinstance(m, dict):
    raise SystemExit("manifest must be a JSON object")
if "source" not in m:
    raise SystemExit("manifest.source is required")
src = m["source"]
if not isinstance(src, str):
    raise SystemExit("manifest.source must be a string")
print(src)
PY
  )" || return 1
  artifact_source_validate "${source}"
}
