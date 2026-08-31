#!/usr/bin/env bash
# Artifact staging + cache contract (ADR-0059 / #260).
# Operator-side write/read for .artifact-cache staging files and content-addressed zips.
#
# artifact_cache_dir ENVIRONMENT_ROOT
#   Print Environment-scoped Artifact cache directory path.
#
# artifact_staging_zip_basename BASENAME SHA256
#   Print content-addressed zip filename: <basename>-<sha256>.zip
#
# artifact_staging_write ENVIRONMENT_ROOT BASENAME ZIP_SOURCE
#   SHA-256 hash zip bytes, copy to cache, write staging record; print sha256 on stdout.
#   Creates .artifact-cache/ when missing.
#
# artifact_staging_read ENVIRONMENT_ROOT BASENAME
#   Read staging, validate 64-char lowercase hex, verify zip exists; print absolute zip path.

_artifact_staging_py_lib() {
  cat <<'PY'
import re
import sys

FULL_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def die(msg):
    raise SystemExit(msg)


def validate_basename(name, label="basename"):
    if not isinstance(name, str) or not name:
        die("%s must be a non-empty string" % label)
    if "/" in name or "\\" in name:
        die("%s must not contain path separators" % label)
    if name == ".." or ".." in name.split("/"):
        die("%s must not be .. or contain .. segments" % label)
    return name


def validate_sha256(value, label="sha256"):
    if not isinstance(value, str) or not FULL_SHA256.match(value):
        die("%s must be 64 lowercase hex chars" % label)
    return value


def validate_staging_contents(raw):
    if raw is None:
        die("staging record is empty")
    if not isinstance(raw, str):
        die("staging record must be text")
    if not raw:
        die("staging record is empty")
    if raw.endswith("\n"):
        body = raw[:-1]
        if "\n" in body:
            die("staging record must be a single line")
    elif "\n" in raw:
        die("staging record must be a single line")
    else:
        body = raw
    if not body:
        die("staging record is empty")
    validate_sha256(body, "staging record")
    return body
PY
}

_artifact_staging_validate_basename() {
  python3 -c "
$(_artifact_staging_py_lib)
validate_basename(sys.argv[1])
" "${1-}"
}

_artifact_staging_sha256_file() {
  local zip_path="${1:?_artifact_staging_sha256_file: zip path required}"
  python3 -c "
import hashlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit('zip source must be a regular file: %s' % path)
h = hashlib.sha256()
with path.open('rb') as fh:
    for chunk in iter(lambda: fh.read(65536), b''):
        h.update(chunk)
print(h.hexdigest())
" "${zip_path}"
}

artifact_cache_dir() {
  local environment_root="${1:?artifact_cache_dir: environment root required}"
  printf '%s\n' "${environment_root}/.artifact-cache"
}

artifact_staging_zip_basename() {
  local basename="${1:?artifact_staging_zip_basename: basename required}"
  local sha256="${2:?artifact_staging_zip_basename: sha256 required}"
  _artifact_staging_validate_basename "${basename}" || return 1
  python3 -c "
$(_artifact_staging_py_lib)
validate_sha256(sys.argv[1])
print('%s-%s.zip' % (validate_basename(sys.argv[2]), sys.argv[1]))
" "${sha256}" "${basename}"
}

artifact_staging_write() {
  local environment_root="${1:?artifact_staging_write: environment root required}"
  local basename="${2:?artifact_staging_write: basename required}"
  local zip_source="${3:?artifact_staging_write: zip source required}"
  local cache_dir sha256 zip_name dest staging_path

  _artifact_staging_validate_basename "${basename}" || return 1
  [[ -d "${environment_root}" ]] || {
    echo "artifact_staging_write: environment root missing: ${environment_root}" >&2
    return 1
  }
  [[ -f "${zip_source}" && ! -L "${zip_source}" ]] || {
    echo "artifact_staging_write: zip source must be a regular file: ${zip_source}" >&2
    return 1
  }

  sha256="$(_artifact_staging_sha256_file "${zip_source}")" || return 1
  cache_dir="$(artifact_cache_dir "${environment_root}")" || return 1
  zip_name="$(artifact_staging_zip_basename "${basename}" "${sha256}")" || return 1
  dest="${cache_dir}/${zip_name}"
  staging_path="${cache_dir}/${basename}.staging"

  mkdir -p "${cache_dir}" || return 1
  cp "${zip_source}" "${dest}" || return 1
  printf '%s\n' "${sha256}" >"${staging_path}" || return 1
  printf '%s\n' "${sha256}"
}

artifact_staging_read() {
  local environment_root="${1:?artifact_staging_read: environment root required}"
  local basename="${2:?artifact_staging_read: basename required}"
  local cache_dir staging_path sha256 zip_name zip_path

  _artifact_staging_validate_basename "${basename}" || return 1
  [[ -d "${environment_root}" ]] || {
    echo "artifact_staging_read: environment root missing: ${environment_root}" >&2
    return 1
  }

  cache_dir="$(artifact_cache_dir "${environment_root}")" || return 1
  staging_path="${cache_dir}/${basename}.staging"
  [[ -f "${staging_path}" && ! -L "${staging_path}" ]] || {
    echo "artifact_staging_read: staging record missing: ${staging_path}" >&2
    return 1
  }

  sha256="$(
    python3 - "${staging_path}" <<PY
import sys
from pathlib import Path

$(_artifact_staging_py_lib)

staging_path = Path(sys.argv[1])
raw = staging_path.read_text(encoding="utf-8")
print(validate_staging_contents(raw))
PY
  )" || {
    echo "artifact_staging_read: invalid staging record: ${staging_path}" >&2
    return 1
  }

  zip_name="$(artifact_staging_zip_basename "${basename}" "${sha256}")" || return 1
  zip_path="${cache_dir}/${zip_name}"
  [[ -f "${zip_path}" && ! -L "${zip_path}" ]] || {
    echo "artifact_staging_read: staged zip missing: ${zip_path}" >&2
    return 1
  }

  python3 - "${cache_dir}" "${zip_name}" <<'PY'
import sys
from pathlib import Path

print(str((Path(sys.argv[1]) / sys.argv[2]).resolve()))
PY
}
