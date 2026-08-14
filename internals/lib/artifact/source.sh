#!/usr/bin/env bash
# Workload Source contract (ADR-0053 / #199).
# Sourced by Mirror / Manifest readers and Host materialize.
#
# artifact_source_validate VALUE
#   Print VALUE when it is exactly "internal", a relative zip path, or an
#   unauthenticated http(s) zip URI. Fail closed otherwise.
#
# artifact_source_kind VALUE
#   Print internal | path | uri after validating VALUE.
#
# artifact_source_from_manifest MANIFEST
#   Read Manifest `source` and validate via artifact_source_validate.
#
# artifact_source_environment_tree_gate TREE
#   Fail closed when Source is not internal and the Environment Workload tree
#   already contains Artifact contracts (provides.json / requires.json).
#   Manifest-less TREE is a no-op (Mirror bag upsert).
#
# artifact_source_symlink_gate TREE
#   Fail closed when any symlink under TREE resolves outside TREE (after
#   resolving TREE itself, so an Environment-level Workload-dir symlink is OK).
#
# artifact_source_path_file_gate TREE
#   When Manifest Source is a zip path: fail closed unless that path is a
#   regular file (not a symlink) under TREE.
#
# artifact_source_tree_gate TREE
#   Operator / Host fail-early: symlink gate, Environment contract gate, path
#   file gate. Manifest-less TREE still gets the symlink walk.
#
# artifact_source_zip_extract ZIP DEST
#   Extract ZIP into DEST (replaced): refuse absolute / `..` members, then peel
#   a sole archive-root directory when it contains provides.json.

_artifact_source_py_validate() {
  python3 -c '
import sys
from urllib.parse import urlparse

value = sys.argv[1]
if value == "internal":
    print(value)
    raise SystemExit(0)
if not value:
    raise SystemExit(
        "Source must be \"internal\", a relative zip path, or an unauthenticated http(s) zip URI"
    )

parsed = urlparse(value)
scheme = (parsed.scheme or "").lower()
if scheme in ("http", "https"):
    if not parsed.netloc:
        raise SystemExit("Source URI must be http(s) with a host")
    path = parsed.path or ""
    if not path.lower().endswith(".zip"):
        raise SystemExit("Source URI path must end with .zip")
    print(value)
    raise SystemExit(0)
if scheme:
    raise SystemExit("Source URI must be http(s) with a host")

if value.startswith("/") or "\\" in value:
    raise SystemExit("Source zip path must be relative to the Workload directory")
parts = value.split("/")
if any(p == "" or p == "." or p == ".." for p in parts):
    raise SystemExit("Source zip path must not contain empty, \".\", or \"..\" segments")
last = parts[-1]
if not last.lower().endswith(".zip") or len(last) <= 4:
    raise SystemExit("Source zip path must end with .zip")
print(value)
' "${1-}"
}

artifact_source_validate() {
  local value="${1-}"
  command -v python3 >/dev/null || {
    echo "artifact_source_validate: python3 required" >&2
    return 1
  }
  _artifact_source_py_validate "${value}"
}

artifact_source_kind() {
  local value kind
  command -v python3 >/dev/null || {
    echo "artifact_source_kind: python3 required" >&2
    return 1
  }
  value="$(artifact_source_validate "${1-}")" || return 1
  kind="$(
    python3 -c '
import sys
from urllib.parse import urlparse

value = sys.argv[1]
if value == "internal":
    print("internal")
    raise SystemExit(0)
parsed = urlparse(value)
scheme = (parsed.scheme or "").lower()
if scheme in ("http", "https"):
    print("uri")
else:
    print("path")
' "${value}"
  )" || return 1
  printf '%s\n' "${kind}"
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

artifact_source_environment_tree_gate() {
  local tree="${1:?artifact_source_environment_tree_gate: Workload tree required}"
  local manifest source

  [[ -d "${tree}" ]] || {
    echo "artifact_source_environment_tree_gate: tree missing: ${tree}" >&2
    return 1
  }
  manifest="${tree}/manifest.json"
  if [[ ! -f "${manifest}" ]]; then
    return 0
  fi
  source="$(artifact_source_from_manifest "${manifest}")" || return 1
  [[ "${source}" != "internal" ]] || return 0

  if [[ -e "${tree}/provides.json" || -L "${tree}/provides.json" ]]; then
    echo "zip Source Environment tree must not contain provides.json: ${tree}" >&2
    return 1
  fi
  if [[ -e "${tree}/requires.json" || -L "${tree}/requires.json" ]]; then
    echo "zip Source Environment tree must not contain requires.json: ${tree}" >&2
    return 1
  fi
  return 0
}

artifact_source_symlink_gate() {
  local tree="${1:?artifact_source_symlink_gate: Workload tree required}"
  command -v python3 >/dev/null || {
    echo "artifact_source_symlink_gate: python3 required" >&2
    return 1
  }
  [[ -d "${tree}" ]] || {
    echo "artifact_source_symlink_gate: tree missing: ${tree}" >&2
    return 1
  }
  python3 - "${tree}" <<'PY'
import os
import sys
from pathlib import Path

tree = Path(sys.argv[1])
root = tree.resolve()
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    for name in dirnames + filenames:
        path = Path(dirpath) / name
        if not path.is_symlink():
            continue
        target = Path(os.path.realpath(str(path)))
        try:
            common = os.path.commonpath([str(root), str(target)])
        except ValueError:
            print(
                "Workload tree symlink escapes Workload directory: %s" % path,
                file=sys.stderr,
            )
            raise SystemExit(1)
        if common != str(root):
            print(
                "Workload tree symlink escapes Workload directory: %s" % path,
                file=sys.stderr,
            )
            raise SystemExit(1)
PY
}

artifact_source_path_file_gate() {
  local tree="${1:?artifact_source_path_file_gate: Workload tree required}"
  local manifest source kind zip_path

  [[ -d "${tree}" ]] || {
    echo "artifact_source_path_file_gate: tree missing: ${tree}" >&2
    return 1
  }
  manifest="${tree}/manifest.json"
  if [[ ! -f "${manifest}" ]]; then
    return 0
  fi
  source="$(artifact_source_from_manifest "${manifest}")" || return 1
  kind="$(artifact_source_kind "${source}")" || return 1
  [[ "${kind}" == "path" ]] || return 0
  zip_path="${tree}/${source}"
  if [[ -L "${zip_path}" ]]; then
    echo "zip path Source must be a regular file, not a symlink: ${zip_path}" >&2
    return 1
  fi
  if [[ ! -f "${zip_path}" ]]; then
    echo "zip path Source file missing: ${zip_path}" >&2
    return 1
  fi
  return 0
}

artifact_source_tree_gate() {
  local tree="${1:?artifact_source_tree_gate: Workload tree required}"
  artifact_source_symlink_gate "${tree}" || return 1
  artifact_source_environment_tree_gate "${tree}" || return 1
  artifact_source_path_file_gate "${tree}" || return 1
  return 0
}

artifact_source_zip_extract() {
  local zip_path="${1:?artifact_source_zip_extract: zip path required}"
  local dest="${2:?artifact_source_zip_extract: destination dir required}"
  command -v python3 >/dev/null || {
    echo "artifact_source_zip_extract: python3 required" >&2
    return 1
  }
  [[ -f "${zip_path}" && ! -L "${zip_path}" ]] || {
    echo "artifact_source_zip_extract: zip must be a regular file: ${zip_path}" >&2
    return 1
  }
  python3 - "${zip_path}" "${dest}" <<'PY'
import os
import shutil
import sys
import zipfile
from pathlib import Path

zip_path = Path(sys.argv[1])
dest = Path(sys.argv[2])

def member_ok(name):
    raw = name.replace("\\", "/")
    if raw.startswith("/"):
        raise SystemExit("zip member path not allowed: %s" % name)
    parts = raw.split("/")
    if parts and parts[-1] == "":
        parts = parts[:-1]
    if any(p == "" or p == "." or p == ".." for p in parts):
        raise SystemExit("zip member path not allowed: %s" % name)

if dest.exists():
    shutil.rmtree(dest)
dest.mkdir(parents=True)

try:
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            member_ok(info.filename)
        zf.extractall(dest)
except zipfile.BadZipFile:
    raise SystemExit("invalid zip: %s" % zip_path)

entries = list(dest.iterdir())
if (
    len(entries) == 1
    and entries[0].is_dir()
    and not entries[0].is_symlink()
    and (entries[0] / "provides.json").is_file()
):
    wrapper = entries[0]
    peeled = dest.parent / (dest.name + ".peel")
    if peeled.exists():
        shutil.rmtree(peeled)
    wrapper.rename(peeled)
    dest.rmdir()
    peeled.rename(dest)
PY
}
