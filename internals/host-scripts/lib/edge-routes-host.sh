#!/usr/bin/env bash
# Edge Route install helpers (sourced by Edge Component Setup gather).
# Expects: ROUTES_DIR. Intent run also expects WANT_LIST (Host acme/want-list path).
# Optional: USER_NAME for ownership.
#
# Sets EDGE_ROUTES_CHANGED=1 when installed Route file contents for a reconcile/gather
# changed; else 0. Edge Component Setup uses that flag to skip front-door bounce when
# gather is a noop.
# ADR-0028 / ADR-0053: Routes are Binding-attached Provides fragments; Setup fails closed
# if a Binding FQDN is not on the Domain want-list. Edge interior is <wl>--<fqdn>.conf.
# ADR-0040: edge_gather_workload_routes collects Intent-run Declarations across Workloads.

_edge_routes_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=edge-want-list-host.sh
source "${_edge_routes_lib_dir}/edge-want-list-host.sh"
# shellcheck source=workload-manifest-host.sh
source "${_edge_routes_lib_dir}/workload-manifest-host.sh"
# Host Volume ships copies of internals/lib/artifact/{binding,provides,requires}.sh
# beside this file (ensure-fabric / ensure-components). Unit Tests source in-tree.
_binding_lib="${_edge_routes_lib_dir}/binding.sh"
if [[ ! -f "${_binding_lib}" ]]; then
  _binding_lib="${_edge_routes_lib_dir}/../../lib/artifact/binding.sh"
fi
if [[ ! -f "${_binding_lib}" ]]; then
  echo "edge-routes-host: Binding library missing" >&2
  return 1
fi
# shellcheck source=../../lib/artifact/binding.sh
source "${_binding_lib}"

# Remove fulfilled `<name>--*` Routes for one Workload.
edge_remove_workload_installed_routes() {
  local wl_name="$1"
  local f
  if compgen -G "${ROUTES_DIR}/${wl_name}--*" >/dev/null; then
    for f in "${ROUTES_DIR}/${wl_name}"--*; do
      rm -f "${f}"
    done
  fi
}

# Clear all fulfilled Workload Routes under Edge data (ROUTES_DIR). Domain fronts stay
# under DOMAINS_DIR — this only touches Route fulfillment installs (ADR-0043 cold pre).
edge_clear_fulfilled_routes() {
  local f

  mkdir -p "${ROUTES_DIR}"
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    rm -f "${f}"
  done < <(find "${ROUTES_DIR}" -maxdepth 1 -type f 2>/dev/null)
}

# Fingerprint installed Route directory contents (paths + bytes), or "none".
_edge_routes_fingerprint() {
  local f
  local -a files=()

  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    files+=("${f}")
  done < <(find "${ROUTES_DIR}" -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort)

  if [[ ${#files[@]} -eq 0 ]]; then
    printf '%s\n' "none"
    return 0
  fi
  for f in "${files[@]}"; do
    printf '%s\0' "${f}"
    cat "${f}"
  done | sha256sum
}

# Stage Binding×Provides fragments into dest as <fqdn>.conf (Edge interior naming).
# Missing Binding/Provides/Requires → empty dest (do not fulfill). Invalid → fail closed.
# Does not mutate ROUTES_DIR.
_edge_stage_bound_routes() {
  local wl_dir="$1"
  local dest_dir="$2"
  local want_tmp
  local binding provides requires

  mkdir -p "${dest_dir}"
  [[ -n "${wl_dir}" && -d "${wl_dir}" ]] || return 0

  binding="${wl_dir}/binding.json"
  provides="${wl_dir}/provides.json"
  requires="${wl_dir}/requires.json"
  if [[ ! -f "${binding}" || ! -f "${provides}" || ! -f "${requires}" ]]; then
    return 0
  fi

  [[ -n "${WANT_LIST:-}" ]] || {
    echo "edge_reconcile_workload_routes: WANT_LIST is unset" >&2
    return 1
  }

  want_tmp="$(umask 077; mktemp "${TMPDIR:-/tmp}/edge-routes-want.XXXXXX")"
  edge_want_list_fqdns >"${want_tmp}" || {
    rm -f "${want_tmp}"
    return 1
  }
  artifact_binding_fulfill "${binding}" "${provides}" "${requires}" "${want_tmp}" || {
    rm -f "${want_tmp}"
    return 1
  }
  rm -f "${want_tmp}"

  python3 - "${wl_dir}" "${dest_dir}" <<'PY'
import json, pathlib, sys

wl_dir = pathlib.Path(sys.argv[1])
dest_dir = pathlib.Path(sys.argv[2])

with open(wl_dir / "binding.json", encoding="utf-8") as f:
    binding = json.load(f)
domains = binding.get("domains") or {}

for fqdn, routes in domains.items():
    dest = dest_dir / f"{fqdn}.conf"
    if dest.name != f"{fqdn}.conf":
        raise SystemExit(f"Binding FQDN {fqdn!r} must be a single path segment")
    chunks = []
    for rel in routes:
        if not isinstance(rel, str) or rel == "":
            raise SystemExit(f"Binding route path for {fqdn!r} must be a non-empty string")
        parts = pathlib.PurePosixPath(rel).parts
        if rel.startswith("/") or ".." in parts:
            raise SystemExit(
                f"Binding route path {rel!r} must be relative to the Workload tree without .."
            )
        src = wl_dir / rel
        if not src.is_file():
            raise SystemExit(f"Provides route fragment missing: {rel}")
        data = src.read_text(encoding="utf-8")
        if data and not data.endswith("\n"):
            data += "\n"
        chunks.append(data)
    if not chunks:
        continue
    dest.write_text("".join(chunks), encoding="utf-8")
PY
}

# Reconcile one Workload's installed Routes from Binding × Provides (Intent run) or remove them.
# Args: workload_name intent workload_tree
# Missing Binding/Provides/Requires on run → zero Routes (do not fulfill).
edge_reconcile_workload_routes() {
  local wl_name="$1"
  local intent="$2"
  local wl_dir="${3:-}"
  local routes_before routes_after
  local staged="" src base dest

  mkdir -p "${ROUTES_DIR}"
  EDGE_ROUTES_CHANGED=0

  if [[ "${intent}" == "run" ]]; then
    staged="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/edge-routes-stage.XXXXXX")"
    if ! _edge_stage_bound_routes "${wl_dir}" "${staged}"; then
      rm -rf "${staged}"
      return 1
    fi
  fi

  routes_before="$(_edge_routes_fingerprint)"

  edge_remove_workload_installed_routes "${wl_name}"

  if [[ "${intent}" == "run" && -n "${staged}" ]]; then
    for src in "${staged}"/*; do
      [[ -f "${src}" ]] || continue
      base="$(basename "${src}")"
      # Skip hidden / non-regular noise; Domain fronts include *--<fqdn>.conf
      [[ "${base}" == *.conf ]] || continue
      dest="${ROUTES_DIR}/${wl_name}--${base}"
      install -m 0644 "${src}" "${dest}"
    done
    rm -rf "${staged}"
  fi

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${ROUTES_DIR}" 2>/dev/null || true
  fi

  routes_after="$(_edge_routes_fingerprint)"
  if [[ "${routes_before}" != "${routes_after}" ]]; then
    EDGE_ROUTES_CHANGED=1
  fi
  export EDGE_ROUTES_CHANGED
}

# Workload name encoded in an Edge interior Route basename (<wl>--<fqdn>.conf).
_edge_installed_route_workload_name() {
  local base="$1"
  case "${base}" in
    *--*)
      printf '%s\n' "${base%%--*}"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

# Gather Route Declarations from Binding × Provides and fulfill into Edge interior.
# Intent run → validate want-list and install; stop/trash → drop that Workload's fulfillment.
# Missing Binding/Provides → do not fulfill. Workloads missing from SoT leave orphan Edge
# installs, which are removed.
# Args: workloads_root (defaults to ambient WORKLOADS_ROOT).
# Sets EDGE_ROUTES_CHANGED=1 when the fulfilled Route set changed; else 0 (noop).
edge_gather_workload_routes() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"
  local routes_before routes_after
  local wl_dir wl_name intent f base installed_wl

  if [[ -z "${workloads_root}" ]]; then
    echo "edge_gather_workload_routes: workloads root required (arg or WORKLOADS_ROOT)" >&2
    return 1
  fi

  mkdir -p "${ROUTES_DIR}"
  EDGE_ROUTES_CHANGED=0
  routes_before="$(_edge_routes_fingerprint)"

  if [[ -d "${workloads_root}" ]]; then
    for wl_dir in "${workloads_root}"/*; do
      [[ -d "${wl_dir}" && -f "${wl_dir}/manifest.json" ]] || continue
      wl_name="$(basename "${wl_dir}")"
      intent="$(workload_manifest_intent "${wl_dir}/manifest.json")" || return 1
      edge_reconcile_workload_routes "${wl_name}" "${intent}" "${wl_dir}" || return 1
    done
  fi

  # Drop fulfillments whose Workload SoT tree (with Manifest) is gone.
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    base="$(basename "${f}")"
    installed_wl="$(_edge_installed_route_workload_name "${base}")"
    [[ -n "${installed_wl}" ]] || continue
    if [[ ! -f "${workloads_root}/${installed_wl}/manifest.json" ]]; then
      rm -f "${f}"
    fi
  done < <(find "${ROUTES_DIR}" -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort)

  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${ROUTES_DIR}" 2>/dev/null || true
  fi

  routes_after="$(_edge_routes_fingerprint)"
  if [[ "${routes_before}" != "${routes_after}" ]]; then
    EDGE_ROUTES_CHANGED=1
  else
    EDGE_ROUTES_CHANGED=0
  fi
  export EDGE_ROUTES_CHANGED
}
