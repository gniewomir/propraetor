#!/usr/bin/env bash
# Artifact Prep (ADR-0059 / #261 / #263).
# Operator-side: obtain/build materials per Manifest Source, normalize to Propraetor
# Artifact zip, write .artifact-cache + staging. Deploy/Mirror consume staged zip only.
#
# artifact_prep_zip_from_tree ARTIFACT_ROOT OUTPUT_ZIP [EXCLUDE_ROOT_CSV]
#   Zip Artifact root contents (relative paths). Optional comma-separated root file
#   names to skip (internal: manifest.json,binding.json). Always skips persist/.
#
# artifact_prep_internal_zip WORKLOAD_DIR OUTPUT_ZIP
#   Internal Source zip helper: optional build.json, then zip Workload tree.
#
# artifact_prep_internal / artifact_prep_zip / artifact_prep_git / artifact_prep_local
#   Full Prep for one Source kind: validate, tree gate, obtain, build, zip, stage,
#   verify manifest source unchanged; print sha256 on stdout.
#
# artifact_prep_workload WORKLOAD_DIR
#   Dispatch Prep by Manifest Source kind.
#
# artifact_prep_environment ENV_DIR
#   Discover Workloads with manifest.json, Prep each; print count on stdout.

_prep_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=staging.sh
source "${_prep_lib_dir}/staging.sh"
# shellcheck source=source.sh
source "${_prep_lib_dir}/source.sh"
# shellcheck source=build.sh
source "${_prep_lib_dir}/build.sh"
# shellcheck source=manifest.sh
source "${_prep_lib_dir}/manifest.sh"
# shellcheck source=../environment/environment-workloads.sh
source "${_prep_lib_dir}/../environment/environment-workloads.sh"

artifact_prep_environment() {
  local env_dir="${1:?artifact_prep_environment: ENV_DIR required}"
  local wl_name wl_dir prepped=0

  [[ -d "${env_dir}" ]] || {
    echo "artifact_prep_environment: not a directory: ${env_dir}" >&2
    return 1
  }

  while IFS= read -r wl_name; do
    [[ -n "${wl_name}" ]] || continue
    wl_dir="${env_dir}/${wl_name}"
    [[ -f "${wl_dir}/manifest.json" ]] || continue
    artifact_prep_workload "${wl_dir}" >/dev/null || return 1
    prepped=$((prepped + 1))
  done < <(environment_discover_workloads "${env_dir}")

  printf '%s\n' "${prepped}"
}

artifact_prep_zip_from_tree() {
  local artifact_root="${1:?artifact_prep_zip_from_tree: Artifact root required}"
  local output_zip="${2:?artifact_prep_zip_from_tree: output zip path required}"
  local exclude_root_csv="${3:-}"

  command -v python3 >/dev/null || {
    echo "artifact_prep_zip_from_tree: python3 required" >&2
    return 1
  }
  [[ -d "${artifact_root}" ]] || {
    echo "artifact_prep_zip_from_tree: Artifact root missing: ${artifact_root}" >&2
    return 1
  }

  python3 - "${artifact_root}" "${output_zip}" "${exclude_root_csv}" <<'PY'
import os
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1]).resolve()
out_zip = Path(sys.argv[2])
exclude_raw = sys.argv[3] if len(sys.argv) > 3 else ""
exclude_root = frozenset(
    p for p in exclude_raw.split(",") if p
)


def include_file(rel: str) -> bool:
    if rel in exclude_root:
        return False
    if "persist" in rel.split("/"):
        return False
    return True


if not root.is_dir():
    raise SystemExit("Artifact root is not a directory: %s" % root)

with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d != "persist")
        for name in sorted(filenames):
            path = Path(dirpath) / name
            if path.is_symlink():
                raise SystemExit(
                    "Artifact tree must not contain symlinks in zip: %s"
                    % path.relative_to(root)
                )
            if not path.is_file():
                continue
            rel = path.relative_to(root).as_posix()
            if not include_file(rel):
                continue
            zf.write(path, rel)
PY
}

_artifact_prep_fetch_uri() {
  local uri="${1:?_artifact_prep_fetch_uri: URI required}"
  local extract_root="${2:?_artifact_prep_fetch_uri: extract root required}"
  local zip_path

  command -v curl >/dev/null || {
    echo "artifact_prep: curl required to fetch zip Source URI" >&2
    return 1
  }

  zip_path="$(umask 077; mktemp "${TMPDIR:-/tmp}/artifact-prep-src.XXXXXX.zip")" || return 1
  if ! curl -fsSL --connect-timeout 30 --max-time 300 -o "${zip_path}" "${uri}"; then
    rm -f "${zip_path}"
    echo "artifact_prep: failed to fetch Source zip: ${uri}" >&2
    return 1
  fi
  if ! artifact_source_zip_extract "${zip_path}" "${extract_root}"; then
    rm -f "${zip_path}"
    return 1
  fi
  rm -f "${zip_path}"
}

_artifact_prep_git_obtain() {
  local url="${1:?_artifact_prep_git_obtain: URL required}"
  local commit="${2:?_artifact_prep_git_obtain: commit required}"
  local materials="${3:?_artifact_prep_git_obtain: materials dir required}"

  command -v git >/dev/null || {
    echo "artifact_prep: git required for git Source" >&2
    return 1
  }

  rm -rf "${materials}"
  mkdir -p "${materials}" || return 1
  if ! git -C "${materials}" init --quiet; then
    echo "artifact_prep: git init failed" >&2
    return 1
  fi
  if ! git -C "${materials}" remote add origin "${url}"; then
    echo "artifact_prep: git remote add failed" >&2
    return 1
  fi
  if ! git -C "${materials}" fetch --quiet --depth 1 origin "${commit}"; then
    if ! git -C "${materials}" fetch --quiet origin "${commit}"; then
      echo "artifact_prep: git fetch failed for ${url} @ ${commit}" >&2
      return 1
    fi
  fi
  if ! git -C "${materials}" checkout --quiet --detach "${commit}"; then
    echo "artifact_prep: git checkout failed for commit ${commit}" >&2
    return 1
  fi
  return 0
}

_artifact_prep_finalize() {
  local workload_dir="${1:?_artifact_prep_finalize: Workload dir required}"
  local materials="${2:?_artifact_prep_finalize: materials dir required}"
  local artifact_root="${3:?_artifact_prep_finalize: Artifact root required}"
  local exclude_root_csv="${4:-}"
  local manifest environment_root basename source_before source_after
  local build_json tmp_zip sha

  manifest="${workload_dir}/manifest.json"
  environment_root="$(cd "${workload_dir}/.." && pwd)"
  basename="$(basename "${workload_dir}")"
  source_before="$(artifact_source_from_manifest "${manifest}")" || return 1

  build_json="${artifact_root}/build.json"
  artifact_build_run "${materials}" "${artifact_root}" "${build_json}" || return 1

  tmp_zip="$(umask 077; mktemp "${TMPDIR:-/tmp}/artifact-prep.XXXXXX").zip" || return 1
  if ! artifact_prep_zip_from_tree "${artifact_root}" "${tmp_zip}" "${exclude_root_csv}"; then
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
    echo "artifact_prep: manifest source changed during prep" >&2
    return 1
  fi

  printf '%s\n' "${sha}"
}

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
  artifact_prep_zip_from_tree "${workload_dir}" "${output_zip}" "manifest.json,binding.json"
}

artifact_prep_internal() {
  local workload_dir="${1:?artifact_prep_internal: Workload dir required}"
  local manifest source_before

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

  _artifact_prep_finalize "${workload_dir}" "${workload_dir}" "${workload_dir}" \
    "manifest.json,binding.json"
}

artifact_prep_zip() {
  local workload_dir="${1:?artifact_prep_zip: Workload dir required}"
  local source="${2:?artifact_prep_zip: Source required}"
  local extract_tmp materials artifact_root zip_path zip_uri

  extract_tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-prep-zip.XXXXXX")" || return 1
  if zip_path="$(artifact_source_zip_path "${source}" 2>/dev/null)"; then
    zip_path="${workload_dir}/${zip_path}"
    if ! artifact_source_zip_extract "${zip_path}" "${extract_tmp}"; then
      rm -rf "${extract_tmp}"
      return 1
    fi
  elif zip_uri="$(artifact_source_zip_uri "${source}" 2>/dev/null)"; then
    if ! _artifact_prep_fetch_uri "${zip_uri}" "${extract_tmp}"; then
      rm -rf "${extract_tmp}"
      return 1
    fi
  else
    echo "artifact_prep_zip: zip Source must have path or uri" >&2
    rm -rf "${extract_tmp}"
    return 1
  fi

  materials="${extract_tmp}"
  artifact_root="${extract_tmp}"
  _artifact_prep_finalize "${workload_dir}" "${materials}" "${artifact_root}" "" \
    || { rm -rf "${extract_tmp}"; return 1; }
  rm -rf "${extract_tmp}"
}

artifact_prep_git() {
  local workload_dir="${1:?artifact_prep_git: Workload dir required}"
  local source="${2:?artifact_prep_git: Source required}"
  local git_url git_commit art_path extract_tmp materials artifact_root

  git_url="$(artifact_source_git_url "${source}")" || return 1
  git_commit="$(artifact_source_git_commit "${source}")" || return 1
  art_path="$(artifact_source_artifact_path "${source}")" || return 1

  extract_tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-prep-git.XXXXXX")" || return 1
  if ! _artifact_prep_git_obtain "${git_url}" "${git_commit}" "${extract_tmp}"; then
    rm -rf "${extract_tmp}"
    return 1
  fi

  materials="${extract_tmp}"
  artifact_root="$(artifact_source_resolve_artifact_root "${materials}" "${art_path}")" || {
    rm -rf "${extract_tmp}"
    return 1
  }

  _artifact_prep_finalize "${workload_dir}" "${materials}" "${artifact_root}" "" \
    || { rm -rf "${extract_tmp}"; return 1; }
  rm -rf "${extract_tmp}"
}

artifact_prep_local() {
  local workload_dir="${1:?artifact_prep_local: Workload dir required}"
  local source="${2:?artifact_prep_local: Source required}"
  local extract_tmp materials staged_manifest art_path artifact_root

  extract_tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/artifact-prep-local.XXXXXX")" || return 1
  materials="${extract_tmp}/materials"
  staged_manifest="${extract_tmp}/manifest.json"
  cp "${workload_dir}/manifest.json" "${staged_manifest}" || {
    rm -rf "${extract_tmp}"
    return 1
  }

  if ! artifact_source_stage_local_materials "${source}" "${materials}" "${staged_manifest}"; then
    rm -rf "${extract_tmp}"
    return 1
  fi

  art_path="$(artifact_source_artifact_path "$(artifact_source_from_manifest "${staged_manifest}")")" \
    || { rm -rf "${extract_tmp}"; return 1; }
  artifact_root="$(artifact_source_resolve_artifact_root "${materials}" "${art_path}")" || {
    rm -rf "${extract_tmp}"
    return 1
  }

  _artifact_prep_finalize "${workload_dir}" "${materials}" "${artifact_root}" "" \
    || { rm -rf "${extract_tmp}"; return 1; }
  rm -rf "${extract_tmp}"
}

artifact_prep_workload() {
  local workload_dir="${1:?artifact_prep_workload: Workload dir required}"
  local manifest source kind

  [[ -d "${workload_dir}" ]] || {
    echo "artifact_prep_workload: Workload dir missing: ${workload_dir}" >&2
    return 1
  }
  manifest="${workload_dir}/manifest.json"

  artifact_manifest_validate "${manifest}" || return 1
  source="$(artifact_source_from_manifest "${manifest}")" || return 1
  kind="$(artifact_source_kind "${source}")" || return 1
  artifact_source_tree_gate "${workload_dir}" || return 1

  case "${kind}" in
    internal)
      artifact_prep_internal "${workload_dir}"
      ;;
    zip)
      artifact_prep_zip "${workload_dir}" "${source}"
      ;;
    git)
      artifact_prep_git "${workload_dir}" "${source}"
      ;;
    local)
      artifact_prep_local "${workload_dir}" "${source}"
      ;;
    *)
      echo "artifact_prep_workload: unsupported Source kind: ${kind}" >&2
      return 1
      ;;
  esac
}
