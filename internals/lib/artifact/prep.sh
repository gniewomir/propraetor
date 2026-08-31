#!/usr/bin/env bash
# Artifact Prep for internal Source (ADR-0059 / #261).
# Operator-side: zip Environment Workload materials, write Artifact cache + staging.
#
# artifact_prep_internal_zip WORKLOAD_DIR OUTPUT_ZIP
#   Build normalized Artifact zip from internal Workload tree (exclude manifest.json,
#   binding.json, persist/). Optionally run artifact_build_run first. Does not write staging.
#
# artifact_prep_internal WORKLOAD_DIR
#   Full Prep for one internal Workload: validate Source, tree gate, zip, stage,
#   verify manifest source unchanged; print sha256 on stdout.

_prep_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=staging.sh
source "${_prep_lib_dir}/staging.sh"
# shellcheck source=source.sh
source "${_prep_lib_dir}/source.sh"
# shellcheck source=build.sh
source "${_prep_lib_dir}/build.sh"
# shellcheck source=manifest.sh
source "${_prep_lib_dir}/manifest.sh"

artifact_prep_internal_zip() {
  local workload_dir="${1:?artifact_prep_internal_zip: Workload dir required}"
  local output_zip="${2:?artifact_prep_internal_zip: output zip path required}"
  local build_json="${workload_dir}/build.json"

  command -v python3 >/dev/null || {
    echo "artifact_prep_internal_zip: python3 required" >&2
    return 1
  }
  [[ -d "${workload_dir}" ]] || {
    echo "artifact_prep_internal_zip: Workload dir missing: ${workload_dir}" >&2
    return 1
  }

  artifact_build_run "${workload_dir}" "${workload_dir}" "${build_json}" || return 1

  python3 - "${workload_dir}" "${output_zip}" <<'PY'
import os
import sys
import zipfile
from pathlib import Path

workload = Path(sys.argv[1]).resolve()
out_zip = Path(sys.argv[2])

EXCLUDE_ROOT_FILES = frozenset({"manifest.json", "binding.json"})


def include_file(rel: str) -> bool:
    if rel in EXCLUDE_ROOT_FILES:
        return False
    parts = rel.split("/")
    if "persist" in parts:
        return False
    return True

if not workload.is_dir():
    raise SystemExit("Workload dir is not a directory: %s" % workload)

with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for dirpath, dirnames, filenames in os.walk(workload, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d != "persist")
        for name in sorted(filenames):
            path = Path(dirpath) / name
            if path.is_symlink():
                raise SystemExit(
                    "Workload tree must not contain symlinks in Artifact zip: %s"
                    % path.relative_to(workload)
                )
            if not path.is_file():
                continue
            rel = path.relative_to(workload).as_posix()
            if not include_file(rel):
                continue
            zf.write(path, rel)
PY
}

artifact_prep_internal() {
  local workload_dir="${1:?artifact_prep_internal: Workload dir required}"
  local manifest environment_root basename source_before source_after tmp_zip sha

  [[ -d "${workload_dir}" ]] || {
    echo "artifact_prep_internal: Workload dir missing: ${workload_dir}" >&2
    return 1
  }
  manifest="${workload_dir}/manifest.json"

  artifact_manifest_validate "${manifest}" || return 1

  source_before="$(artifact_source_from_manifest "${manifest}")" || return 1
  [[ "$(artifact_source_kind "${source_before}")" == "internal" ]] || {
    echo "artifact_prep_internal: Source kind must be internal" >&2
    return 1
  }

  artifact_source_tree_gate "${workload_dir}" || return 1

  environment_root="$(cd "${workload_dir}/.." && pwd)"
  basename="$(basename "${workload_dir}")"

  tmp_zip="$(umask 077; mktemp "${TMPDIR:-/tmp}/artifact-prep.XXXXXX").zip" || return 1
  if ! artifact_prep_internal_zip "${workload_dir}" "${tmp_zip}"; then
    rm -f "${tmp_zip}"
    return 1
  fi

  sha="$(artifact_staging_write "${environment_root}" "${basename}" "${tmp_zip}")" || {
    rm -f "${tmp_zip}"
    return 1
  }
  rm -f "${tmp_zip}"

  source_after="$(artifact_source_from_manifest "${manifest}")" || return 1
  if [[ "${source_after}" != "${source_before}" ]]; then
    echo "artifact_prep_internal: manifest source changed during prep" >&2
    return 1
  fi

  printf '%s\n' "${sha}"
}
