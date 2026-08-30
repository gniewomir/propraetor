#!/usr/bin/env bash
# Artifact Build (ADR-0058 / #259).
# Host materialize: validate build.json, run container, verify overlay outputs.
#
# artifact_build_validate BUILD_JSON_PATH
#   Fail closed on invalid build.json. Print nothing on success.
#   Keys only: image (non-empty string), command (non-empty string or non-empty
#   JSON array of strings), output (non-empty relative path or non-empty array
#   of relative paths). Output paths: relative; no absolute; no empty / "." /
#   ".." segments (sole "." not allowed).
#
# artifact_build_outputs BUILD_JSON_PATH
#   Print one output path per line after validating.
#
# artifact_build_reserved_output_refuse OUTPUT_PATH
#   Fail closed when OUTPUT_PATH is or is under a reserved Artifact contract
#   name (path segment / exact): provides.json, requires.json, build.json,
#   systemd, persist.
#
# artifact_build_run MATERIALS ARTIFACT_ROOT BUILD_JSON_PATH
#   Host-only. Missing BUILD_JSON_PATH ⇒ no-op success. Present ⇒ validate,
#   refuse reserved outputs, snapshot contract files/dirs, run:
#     podman run --rm -v MATERIALS:/materials:rw \
#       -w /materials/<relpath MATERIALS→ARTIFACT_ROOT> IMAGE [command…]
#   String command runs via `sh -c`; array command is argv after IMAGE.
#   After success: contract files/dirs unchanged; each output exists under
#   ARTIFACT_ROOT.

_artifact_build_py_lib() {
  cat <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

RESERVED_SEGMENTS = frozenset(
    ("provides.json", "requires.json", "build.json", "systemd", "persist")
)


def die(msg):
    raise SystemExit(msg)


def output_path_ok(path, label="output"):
    if not isinstance(path, str) or not path:
        die("%s must be a non-empty string" % label)
    if path.startswith("/") or "\\" in path:
        die("%s must be relative" % label)
    parts = path.split("/")
    if any(p == "" or p == "." or p == ".." for p in parts):
        die('%s must not contain empty, ".", or ".." segments' % label)
    return path


def load_build(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except OSError as exc:
        die("build.json unreadable: %s" % exc)
    except ValueError as exc:
        die("build.json is not valid JSON: %s" % exc)
    if not isinstance(raw, dict):
        die("build.json must be a JSON object")
    allowed = {"image", "command", "output"}
    extra = sorted(set(raw) - allowed)
    if extra:
        die("build.json unknown keys: %s" % ", ".join(extra))
    missing = sorted(allowed - set(raw))
    if missing:
        die("build.json missing keys: %s" % ", ".join(missing))

    image = raw["image"]
    if not isinstance(image, str) or not image:
        die("build.json image must be a non-empty string")

    command = raw["command"]
    if isinstance(command, str):
        if not command:
            die("build.json command must be a non-empty string")
    elif isinstance(command, list):
        if not command:
            die("build.json command array must be non-empty")
        for i, item in enumerate(command):
            if not isinstance(item, str) or not item:
                die(
                    "build.json command[%d] must be a non-empty string" % i
                )
    else:
        die("build.json command must be a string or array of strings")

    output = raw["output"]
    if isinstance(output, str):
        outputs = [output_path_ok(output, "build.json output")]
    elif isinstance(output, list):
        if not output:
            die("build.json output array must be non-empty")
        outputs = []
        for i, item in enumerate(output):
            outputs.append(
                output_path_ok(item, "build.json output[%d]" % i)
            )
    else:
        die("build.json output must be a string or array of strings")

    return {"image": image, "command": command, "output": outputs}


def reserved_refuse(path):
    if not isinstance(path, str) or not path:
        die("output path must be a non-empty string")
    # Normalize separators only; do not resolve filesystem.
    cleaned = path.replace("\\", "/").strip("/")
    if not cleaned:
        die("output path must be a non-empty relative path")
    parts = [p for p in cleaned.split("/") if p != ""]
    for part in parts:
        if part in RESERVED_SEGMENTS:
            die(
                "Artifact Build output must not target reserved path segment "
                "%r: %s" % (part, path)
            )


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_fingerprint(root, name):
    """Fingerprint a file or directory under root; None if absent."""
    path = os.path.join(root, name)
    if os.path.isfile(path) and not os.path.islink(path):
        return "file:%s" % file_sha256(path)
    if os.path.isdir(path):
        h = hashlib.sha256()
        entries = []
        for dirpath, dirnames, filenames in os.walk(path):
            dirnames.sort()
            for fname in sorted(filenames):
                fp = os.path.join(dirpath, fname)
                rel = os.path.relpath(fp, root)
                if os.path.islink(fp) or not os.path.isfile(fp):
                    entries.append("%s:special" % rel)
                    continue
                entries.append("%s:%s" % (rel, file_sha256(fp)))
        for entry in sorted(entries):
            h.update(entry.encode("utf-8"))
            h.update(b"\0")
        return "dir:%s" % h.hexdigest()
    if os.path.lexists(path):
        return "other"
    return None
PY
}

artifact_build_validate() {
  local path="${1:?artifact_build_validate: build.json path required}"
  command -v python3 >/dev/null || {
    echo "artifact_build_validate: python3 required" >&2
    return 1
  }
  [[ -f "${path}" ]] || {
    echo "artifact_build_validate: missing: ${path}" >&2
    return 1
  }
  python3 -c "
$(_artifact_build_py_lib)
load_build(sys.argv[1])
" "${path}" >/dev/null
}

artifact_build_outputs() {
  local path="${1:?artifact_build_outputs: build.json path required}"
  command -v python3 >/dev/null || {
    echo "artifact_build_outputs: python3 required" >&2
    return 1
  }
  artifact_build_validate "${path}" || return 1
  python3 -c "
$(_artifact_build_py_lib)
for p in load_build(sys.argv[1])['output']:
    print(p)
" "${path}"
}

artifact_build_reserved_output_refuse() {
  local path="${1:?artifact_build_reserved_output_refuse: output path required}"
  command -v python3 >/dev/null || {
    echo "artifact_build_reserved_output_refuse: python3 required" >&2
    return 1
  }
  python3 -c "
$(_artifact_build_py_lib)
reserved_refuse(sys.argv[1])
" "${path}"
}

_artifact_build_relpath_materials_to_artifact() {
  local materials="${1:?}"
  local artifact_root="${2:?}"
  python3 -c "
$(_artifact_build_py_lib)
materials = Path(sys.argv[1]).resolve()
artifact = Path(sys.argv[2]).resolve()
if not materials.is_dir():
    die('materials is not a directory: %s' % materials)
if not artifact.is_dir():
    die('Artifact root is not a directory: %s' % artifact)
try:
    common = os.path.commonpath([str(materials), str(artifact)])
except ValueError:
    die('Artifact root escapes materials')
if common != str(materials):
    die('Artifact root escapes materials')
print(os.path.relpath(str(artifact), str(materials)))
" "${materials}" "${artifact_root}"
}

_artifact_build_snapshot_contracts() {
  local artifact_root="${1:?}"
  python3 -c "
$(_artifact_build_py_lib)
root = sys.argv[1]
for name in ('provides.json', 'requires.json', 'build.json', 'systemd', 'persist'):
    fp = tree_fingerprint(root, name)
    if fp is not None:
        print('%s\t%s' % (name, fp))
" "${artifact_root}"
}

_artifact_build_verify_contracts() {
  local artifact_root="${1:?}"
  local before="${2:?}"
  local after
  after="$(_artifact_build_snapshot_contracts "${artifact_root}")" || return 1
  python3 -c "
$(_artifact_build_py_lib)

def parse(blob):
    out = {}
    for line in blob.splitlines():
        if not line.strip():
            continue
        name, fp = line.split('\t', 1)
        out[name] = fp
    return out

before = parse(sys.argv[1])
after = parse(sys.argv[2])
for name, fp in before.items():
    if name not in after:
        die('Artifact Build must not remove reserved contract: %s' % name)
    if after[name] != fp:
        die('Artifact Build must not modify reserved contract: %s' % name)
" "${before}" "${after}"
}

# Fingerprint every file under Artifact root (relative path + sha256), one per line.
_artifact_build_snapshot_tree() {
  local artifact_root="${1:?}"
  python3 -c "
$(_artifact_build_py_lib)
root = Path(sys.argv[1]).resolve()
rows = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames[:] = sorted(dirnames)
    for name in sorted(filenames):
        path = Path(dirpath) / name
        if path.is_symlink() or not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b''):
                h.update(chunk)
        rows.append('%s\t%s' % (rel, h.hexdigest()))
for row in rows:
    print(row)
" "${artifact_root}"
}

# After build: only declared output paths (files or trees) may differ from pre-build.
_artifact_build_verify_output_overlay() {
  local artifact_root="${1:?}"
  local before="${2:?}"
  local build_json="${3:?}"
  local after outputs
  after="$(_artifact_build_snapshot_tree "${artifact_root}")" || return 1
  outputs="$(artifact_build_outputs "${build_json}")" || return 1
  python3 -c "
$(_artifact_build_py_lib)

def parse(blob):
    out = {}
    for line in blob.splitlines():
        if not line.strip():
            continue
        rel, fp = line.split('\t', 1)
        out[rel] = fp
    return out

def allowed(rel, outputs):
    for out in outputs:
        if rel == out or rel.startswith(out + '/'):
            return True
    return False

before = parse(sys.argv[1])
after = parse(sys.argv[2])
outputs = [ln for ln in sys.argv[3].splitlines() if ln.strip()]
all_rels = set(before) | set(after)
for rel in sorted(all_rels):
    if allowed(rel, outputs):
        continue
    if rel not in before:
        die('Artifact Build must not create non-output path: %s' % rel)
    if rel not in after:
        die('Artifact Build must not remove non-output path: %s' % rel)
    if before[rel] != after[rel]:
        die('Artifact Build must not modify non-output path: %s' % rel)
" "${before}" "${after}" "${outputs}"
}

artifact_build_run() {
  local materials="${1:?artifact_build_run: materials dir required}"
  local artifact_root="${2:?artifact_build_run: Artifact root required}"
  local build_json="${3:?artifact_build_run: build.json path required}"
  local rel workdir image cmd_kind snapshot tree_snap out_path line
  local -a podman_cmd cmd_argv

  if [[ ! -f "${build_json}" ]]; then
    return 0
  fi

  command -v python3 >/dev/null || {
    echo "artifact_build_run: python3 required" >&2
    return 1
  }
  command -v podman >/dev/null || {
    echo "artifact_build_run: podman required" >&2
    return 1
  }
  [[ -d "${materials}" ]] || {
    echo "artifact_build_run: materials missing: ${materials}" >&2
    return 1
  }
  [[ -d "${artifact_root}" ]] || {
    echo "artifact_build_run: Artifact root missing: ${artifact_root}" >&2
    return 1
  }

  artifact_build_validate "${build_json}" || return 1

  while IFS= read -r out_path; do
    [[ -n "${out_path}" ]] || continue
    artifact_build_reserved_output_refuse "${out_path}" || return 1
  done < <(artifact_build_outputs "${build_json}")

  rel="$(_artifact_build_relpath_materials_to_artifact "${materials}" "${artifact_root}")" || {
    echo "artifact_build_run: Artifact root must be under materials" >&2
    return 1
  }
  if [[ "${rel}" == "." ]]; then
    workdir="/materials"
  else
    workdir="/materials/${rel}"
  fi

  image="$(
    python3 -c "
$(_artifact_build_py_lib)
print(load_build(sys.argv[1])['image'])
" "${build_json}"
  )" || return 1

  cmd_kind="$(
    python3 -c "
$(_artifact_build_py_lib)
c = load_build(sys.argv[1])['command']
print('string' if isinstance(c, str) else 'argv')
" "${build_json}"
  )" || return 1

  snapshot="$(_artifact_build_snapshot_contracts "${artifact_root}")" || return 1
  tree_snap="$(_artifact_build_snapshot_tree "${artifact_root}")" || return 1

  podman_cmd=(
    podman run --rm
    -v "${materials}:/materials:rw"
    -w "${workdir}"
    "${image}"
  )

  if [[ "${cmd_kind}" == "string" ]]; then
    line="$(
      python3 -c "
$(_artifact_build_py_lib)
print(load_build(sys.argv[1])['command'])
" "${build_json}"
    )" || return 1
    podman_cmd+=(sh -c "${line}")
  else
    cmd_argv=()
    while IFS= read -r -d '' line; do
      cmd_argv+=("${line}")
    done < <(
      python3 -c "
$(_artifact_build_py_lib)
for item in load_build(sys.argv[1])['command']:
    sys.stdout.buffer.write(item.encode('utf-8') + b'\0')
" "${build_json}"
    )
    [[ ${#cmd_argv[@]} -gt 0 ]] || {
      echo "artifact_build_run: empty command argv" >&2
      return 1
    }
    podman_cmd+=("${cmd_argv[@]}")
  fi

  "${podman_cmd[@]}" || {
    echo "artifact_build_run: podman build failed" >&2
    return 1
  }

  _artifact_build_verify_contracts "${artifact_root}" "${snapshot}" || return 1
  _artifact_build_verify_output_overlay "${artifact_root}" "${tree_snap}" "${build_json}" || return 1

  while IFS= read -r out_path; do
    [[ -n "${out_path}" ]] || continue
    if [[ ! -e "${artifact_root}/${out_path}" ]]; then
      echo "artifact_build_run: missing build output: ${out_path}" >&2
      return 1
    fi
  done < <(artifact_build_outputs "${build_json}")

  return 0
}
