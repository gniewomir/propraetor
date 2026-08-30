#!/usr/bin/env bash
# Workload Source contract (ADR-0053 / ADR-0058 / #199 / #259).
# Sourced by Mirror / Manifest readers and Host materialize.
#
# artifact_source_validate VALUE
#   Print canonical Source when VALUE is "internal", a relative zip path, an
#   unauthenticated http(s) zip URI, or compact JSON for kind git|local.
#
# artifact_source_kind VALUE
#   Print internal | path | uri | git | local after validating VALUE.
#
# artifact_source_from_manifest MANIFEST
#   Read Manifest `source` and validate via artifact_source_validate.
#
# artifact_source_git_url / artifact_source_git_commit / artifact_source_artifact_path VALUE
#   Field readers for object Sources (path also works for local).
#
# artifact_source_resolve_artifact_root MATERIALS REL
#   Resolve REL under MATERIALS; refuse absolute / .. / escape.
#
# artifact_source_stage_local_materials SOURCE DEST
#   Operator-only: copy Projects root into DEST (materials for local Source).
#   Requires PROPRAETOR_PROJECTS_ROOT; Artifact path must exist under that root.
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

_artifact_source_py_lib() {
  cat <<'PY'
import json
import re
import sys
from urllib.parse import urlparse

FULL_SHA = re.compile(r"^[0-9a-fA-F]{40}$")


def die(msg):
    raise SystemExit(msg)


def rel_path_ok(path, label):
    if not isinstance(path, str) or not path:
        die("%s must be a non-empty string" % label)
    if path.startswith("/") or "\\" in path:
        die("%s must be relative" % label)
    parts = path.split("/")
    if any(p == "" or p == ".." for p in parts):
        die("%s must not contain empty or \"..\" segments" % label)
    if any(p == "." for p in parts[:-1]) or (len(parts) > 1 and parts[-1] == "."):
        die("%s must not contain \".\" segments except sole \".\"" % label)
    if path != "." and any(p == "." for p in parts):
        die("%s must not contain \".\" segments except sole \".\"" % label)
    return path


def validate_zip_string(value):
    if value == "internal":
        return value
    if not value:
        die(
            'Source must be "internal", a relative zip path, an unauthenticated '
            "http(s) zip URI, or an object {kind:git|local,...}"
        )
    parsed = urlparse(value)
    scheme = (parsed.scheme or "").lower()
    if scheme in ("http", "https"):
        if not parsed.netloc:
            die("Source URI must be http(s) with a host")
        path = parsed.path or ""
        if not path.lower().endswith(".zip"):
            die("Source URI path must end with .zip")
        return value
    if scheme:
        die("Source URI must be http(s) with a host")
    if value.startswith("/") or "\\" in value:
        die("Source zip path must be relative to the Workload directory")
    parts = value.split("/")
    if any(p == "" or p == "." or p == ".." for p in parts):
        die('Source zip path must not contain empty, ".", or ".." segments')
    last = parts[-1]
    if not last.lower().endswith(".zip") or len(last) <= 4:
        die("Source zip path must end with .zip")
    return value


def validate_git(obj):
    extra = sorted(set(obj) - {"kind", "url", "commit", "path"})
    if extra:
        die("git Source unknown keys: " + ", ".join(extra))
    for key in ("url", "commit", "path"):
        if key not in obj:
            die("git Source missing %s" % key)
    url = obj["url"]
    if not isinstance(url, str) or not url:
        die("git Source url must be a non-empty string")
    parsed = urlparse(url)
    if (parsed.scheme or "").lower() != "https" or not parsed.netloc:
        die("git Source url must be https with a host")
    commit = obj["commit"]
    if not isinstance(commit, str) or not FULL_SHA.match(commit):
        die("git Source commit must be a full 40-char hex sha")
    commit = commit.lower()
    path = rel_path_ok(obj["path"], "git Source path")
    return {"kind": "git", "url": url, "commit": commit, "path": path}


def validate_local(obj):
    extra = sorted(set(obj) - {"kind", "path"})
    if extra:
        die("local Source unknown keys: " + ", ".join(extra))
    if "path" not in obj:
        die("local Source missing path")
    path = rel_path_ok(obj["path"], "local Source path")
    return {"kind": "local", "path": path}


def validate_value(raw):
    if isinstance(raw, dict):
        kind = raw.get("kind")
        if kind == "git":
            return validate_git(raw)
        if kind == "local":
            return validate_local(raw)
        die('Source object kind must be "git" or "local"')
    if isinstance(raw, str):
        return validate_zip_string(raw)
    die("Source must be a string or object")


def canonical(value):
    validated = validate_value(value)
    if isinstance(validated, dict):
        return json.dumps(validated, separators=(",", ":"), sort_keys=True)
    return validated


def kind_of(canonical_src):
    if canonical_src == "internal":
        return "internal"
    if canonical_src.startswith("{"):
        obj = json.loads(canonical_src)
        return obj["kind"]
    parsed = urlparse(canonical_src)
    scheme = (parsed.scheme or "").lower()
    if scheme in ("http", "https"):
        return "uri"
    return "path"


def parse_object(canonical_src):
    if not canonical_src.startswith("{"):
        die("Source is not an object kind")
    return json.loads(canonical_src)
PY
}

_artifact_source_py_validate() {
  # VALUE may be a string form or compact JSON object.
  python3 -c "
$(_artifact_source_py_lib)
raw = sys.argv[1]
if raw.startswith('{'):
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        die('Source object is not valid JSON')
else:
    value = raw
print(canonical(value))
" "${1-}"
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
  local value
  command -v python3 >/dev/null || {
    echo "artifact_source_kind: python3 required" >&2
    return 1
  }
  value="$(artifact_source_validate "${1-}")" || return 1
  python3 -c "
$(_artifact_source_py_lib)
print(kind_of(sys.argv[1]))
" "${value}"
}

artifact_source_from_manifest() {
  local manifest="${1:?artifact_source_from_manifest: Manifest path required}"
  command -v python3 >/dev/null || {
    echo "artifact_source_from_manifest: python3 required" >&2
    return 1
  }
  local source
  source="$(
    python3 -c "
$(_artifact_source_py_lib)
with open(sys.argv[1], encoding='utf-8') as f:
    m = json.load(f)
if not isinstance(m, dict):
    die('manifest must be a JSON object')
if 'source' not in m:
    die('manifest.source is required')
print(canonical(m['source']))
" "${manifest}"
  )" || return 1
  printf '%s\n' "${source}"
}

artifact_source_git_url() {
  local value
  value="$(artifact_source_validate "${1-}")" || return 1
  python3 -c "
$(_artifact_source_py_lib)
obj = parse_object(sys.argv[1])
if obj.get('kind') != 'git':
    die('Source is not git')
print(obj['url'])
" "${value}"
}

artifact_source_git_commit() {
  local value
  value="$(artifact_source_validate "${1-}")" || return 1
  python3 -c "
$(_artifact_source_py_lib)
obj = parse_object(sys.argv[1])
if obj.get('kind') != 'git':
    die('Source is not git')
print(obj['commit'])
" "${value}"
}

artifact_source_artifact_path() {
  local value
  value="$(artifact_source_validate "${1-}")" || return 1
  python3 -c "
$(_artifact_source_py_lib)
obj = parse_object(sys.argv[1])
if obj.get('kind') not in ('git', 'local'):
    die('Source has no Artifact path field')
print(obj['path'])
" "${value}"
}

artifact_source_resolve_artifact_root() {
  local materials="${1:?artifact_source_resolve_artifact_root: materials dir required}"
  local rel="${2:?artifact_source_resolve_artifact_root: relative path required}"
  command -v python3 >/dev/null || {
    echo "artifact_source_resolve_artifact_root: python3 required" >&2
    return 1
  }
  [[ -d "${materials}" ]] || {
    echo "artifact_source_resolve_artifact_root: materials missing: ${materials}" >&2
    return 1
  }
  python3 -c "
$(_artifact_source_py_lib)
import os
from pathlib import Path

materials = Path(sys.argv[1]).resolve()
rel = rel_path_ok(sys.argv[2], 'Artifact path')
if rel == '.':
    root = materials
else:
    root = (materials / rel).resolve()
try:
    common = os.path.commonpath([str(materials), str(root)])
except ValueError:
    die('Artifact path escapes materials: %s' % rel)
if common != str(materials):
    die('Artifact path escapes materials: %s' % rel)
if not root.is_dir():
    die('Artifact root is not a directory: %s' % root)
print(root)
" "${materials}" "${rel}"
}

artifact_source_stage_local_materials() {
  local source="${1:?artifact_source_stage_local_materials: Source required}"
  local dest="${2:?artifact_source_stage_local_materials: destination dir required}"
  local root path

  # shellcheck source=../environment/environment.sh
  # projects_root lives beside Environments root; callers have REPO_ROOT set.
  if ! declare -F projects_root >/dev/null 2>&1; then
    local _src_dir
    _src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=../environment/environment.sh
    source "${_src_dir}/../environment/environment.sh"
  fi

  source="$(artifact_source_validate "${source}")" || return 1
  [[ "$(artifact_source_kind "${source}")" == "local" ]] || {
    echo "artifact_source_stage_local_materials: Source kind must be local" >&2
    return 1
  }
  path="$(artifact_source_artifact_path "${source}")" || return 1
  root="$(projects_root)" || return 1
  artifact_source_resolve_artifact_root "${root}" "${path}" >/dev/null || {
    echo "artifact_source_stage_local_materials: Artifact path missing under Projects root: ${path}" >&2
    return 1
  }
  rm -rf "${dest}"
  mkdir -p "${dest}" || return 1
  # Whole Projects root = materials (ADR-0058).
  cp -a "${root}/." "${dest}/" || return 1
  # Re-resolve under staged copy to confirm landing.
  artifact_source_resolve_artifact_root "${dest}" "${path}" >/dev/null || return 1
  return 0
}

artifact_source_environment_tree_gate() {
  local tree="${1:?artifact_source_environment_tree_gate: Workload tree required}"
  local manifest source kind

  [[ -d "${tree}" ]] || {
    echo "artifact_source_environment_tree_gate: tree missing: ${tree}" >&2
    return 1
  }
  manifest="${tree}/manifest.json"
  if [[ ! -f "${manifest}" ]]; then
    return 0
  fi
  source="$(artifact_source_from_manifest "${manifest}")" || return 1
  kind="$(artifact_source_kind "${source}")" || return 1
  [[ "${kind}" != "internal" ]] || return 0

  if [[ -e "${tree}/provides.json" || -L "${tree}/provides.json" ]]; then
    echo "non-internal Source Environment tree must not contain provides.json: ${tree}" >&2
    return 1
  fi
  if [[ -e "${tree}/requires.json" || -L "${tree}/requires.json" ]]; then
    echo "non-internal Source Environment tree must not contain requires.json: ${tree}" >&2
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
