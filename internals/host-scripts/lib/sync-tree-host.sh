#!/usr/bin/env bash
# Sync a source tree into dest without replacing dest's directory inode.
# Overwrites/adds files in place (preserves inodes when cp can) so live bind mounts
# of files under dest stay valid across Fabric/Component re-ensure (ADR-0041 / #155).
# Prunes dest entries absent from src, except owner Persist (ADR-0054): never copy
# `persist/` from src and never prune/replace an existing dest `persist/`.
# Sourced by ensure-*-host scripts.
# Usage: sync_tree_inplace SRC DEST

sync_tree_inplace() {
  local src="${1:?sync_tree_inplace requires SRC}"
  local dest="${2:?sync_tree_inplace requires DEST}"
  local path rel

  [[ -d "${src}" ]] || {
    echo "sync_tree_inplace: source is not a directory: ${src}" >&2
    return 1
  }

  if [[ -e "${src}/persist" || -L "${src}/persist" ]]; then
    echo "sync_tree_inplace: source must not contain persist/ (reserved Persist)" >&2
    return 1
  fi

  mkdir -p "${dest}"
  cp -a "${src}/." "${dest}/"

  while IFS= read -r -d '' path; do
    [[ -n "${path}" ]] || continue
    rel="${path#"${dest}/"}"
    if [[ "${rel}" == "persist" || "${rel}" == persist/* ]]; then
      continue
    fi
    [[ -e "${src}/${rel}" || -L "${src}/${rel}" ]] || rm -rf "${path}"
  done < <(find "${dest}" -mindepth 1 \( -type f -o -type l \) -print0)

  # -depth: deepest dirs first so empty pruned parents can rmdir after children.
  while IFS= read -r -d '' path; do
    [[ -n "${path}" ]] || continue
    rel="${path#"${dest}/"}"
    if [[ "${rel}" == "persist" || "${rel}" == persist/* ]]; then
      continue
    fi
    [[ -e "${src}/${rel}" || -L "${src}/${rel}" ]] || rmdir "${path}" 2>/dev/null || true
  done < <(find "${dest}" -mindepth 1 -depth -type d -print0)
}
