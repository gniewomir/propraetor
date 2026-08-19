#!/usr/bin/env bash
# Workload identity + reserved Component dial basenames (#233).
# Sourced by operator Setup staging and Host apply — one check, both entrypoints.
#
# Public interface:
#   workload_identity_require NAME
#     Fail closed unless NAME is a single non-hidden path segment and not a
#     reserved Component dial basename (database / cache / identity).

workload_identity_require() {
  local wl_name="${1:?workload_identity_require: Workload basename required}"

  if [[ -z "${wl_name}" || "${wl_name}" == "." || "${wl_name}" == ".." ]] ||
    [[ "${wl_name}" == .* ]] ||
    [[ "${wl_name}" == */* ]] ||
    [[ "${wl_name}" =~ [[:space:]] ]]; then
    echo "workload name must be a single non-hidden path segment: '${wl_name}'" >&2
    return 1
  fi
  # Service Network dial name for the Database Component (ADR-0049 / #188).
  if [[ "${wl_name}" == "database" ]]; then
    echo "workload basename 'database' is reserved for the Database Component dial identity" >&2
    return 1
  fi
  # Service Network dial name for the Cache Component (ADR-0055 / #221).
  if [[ "${wl_name}" == "cache" ]]; then
    echo "workload basename 'cache' is reserved for the Cache Component dial identity" >&2
    return 1
  fi
  # Service Network dial name for the Identity Component (ADR-0057 / #252).
  if [[ "${wl_name}" == "identity" ]]; then
    echo "workload basename 'identity' is reserved for the Identity Component dial identity" >&2
    return 1
  fi
  return 0
}

# Workload Identity claim contract validation on staged Workload trees.
# Fail closed for invalid Identity claim payloads so downstream components
# can depend on the contract.
#
# Workload Identity contract summary:
# - Identity claimant is identified by Requires.identity == true.
# - API permission catalog: Provides.permissions is a non-empty map that must
#   include mandatory marker key `${workload-slug}:api` and all keys must match
#   `${workload-slug}:${permission}` (single-colon shape).
# - OIDC client: Provides.oidc_callback (string path starting with `/`) plus
#   Requires.permissions is a non-empty map with the same key/value shape
#   (`<api-slug>:<permission>`). The client may request across multiple APIs.
# - `identity` with neither catalog nor client permission keys fails closed.
workload_identity_claim_validate() {
  local wl_tree="${1:?workload_identity_claim_validate: workload tree required}"
  local wl_name="${2:?workload_identity_claim_validate: workload name required}"
  local requires_path provides_path

  requires_path="${wl_tree}/requires.json"
  provides_path="${wl_tree}/provides.json"
  [[ -f "${requires_path}" ]] || {
    echo "workload_identity_claim_validate: requires.json missing: ${requires_path}" >&2
    return 1
  }
  [[ -f "${provides_path}" ]] || {
    echo "workload_identity_claim_validate: provides.json missing: ${provides_path}" >&2
    return 1
  }

  command -v python3 >/dev/null || {
    echo "workload_identity_claim_validate: python3 required" >&2
    return 1
  }

  python3 - "${requires_path}" "${provides_path}" "${wl_name}" <<'PY'
import json, re, sys

requires_path, provides_path, wl_name = sys.argv[1], sys.argv[2], sys.argv[3]

def fail(msg: str):
    raise SystemExit(msg)

def load_obj(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            obj = json.load(f)
    except Exception as e:
        fail(f"Identity claim: failed to load JSON {path}: {e}")
    if not isinstance(obj, dict):
        fail(f"Identity claim: {path} must be a JSON object")
    return obj

def validate_permissions_map(raw, path_label: str):
    if not isinstance(raw, dict):
        fail(f"Identity claim: {path_label}.permissions must be an object")
    if not raw:
        fail(f"Identity claim: {path_label}.permissions must be non-empty")
    out = {}
    for k, v in raw.items():
        if not isinstance(k, str) or not k:
            fail(f"Identity claim: {path_label}.permissions keys must be non-empty strings")
        if not isinstance(v, str) or not v:
            fail(f"Identity claim: {path_label}.permissions values must be non-empty strings")
        out[k] = v
    return out

def validate_api_catalog_keys(keys):
    # Workload-slug is defined by the mandatory marker key: `<workload-slug>:api`.
    marker_keys = []
    for k in keys:
        parts = k.split(":")
        if len(parts) != 2:
            fail(f"Identity claim: API permission key must be single-colon: {k!r}")
        slug, perm = parts
        if not slug:
            fail(f"Identity claim: API permission key slug must be non-empty: {k!r}")
        if perm == "api":
            marker_keys.append(k)

    if len(marker_keys) != 1:
        fail(
            "Identity claim: API permission catalog must include exactly one mandatory marker key "
            f"`<workload-slug>:api` (got marker keys: {sorted(marker_keys)!r})"
        )

    workload_slug = marker_keys[0].split(":")[0]
    marker_key = f"{workload_slug}:api"

    # Validate convention for all keys: `${workload-slug}:${permission}` where permission
    # part is non-empty and must be single-colon shaped.
    for k in keys:
        parts = k.split(":")
        if len(parts) != 2:
            fail(f"Identity claim: API permission key must be single-colon: {k!r}")
        slug, perm = parts
        if slug != workload_slug:
            fail(
                "Identity claim: API permission key must use the same workload-slug as marker "
                f"{marker_key!r}: {k!r}"
            )
        if not perm:
            fail(f"Identity claim: API permission key perm part empty: {k!r}")

    return workload_slug

def validate_client_keys(keys):
    for k in keys:
        parts = k.split(":")
        if len(parts) != 2:
            fail(f"Identity claim: client permission key must be single-colon: {k!r}")
        slug, perm = parts
        if not slug or not perm:
            fail(f"Identity claim: client permission key slug/perm must be non-empty: {k!r}")

requires = load_obj(requires_path)
provides = load_obj(provides_path)

identity = requires.get("identity", None)
catalog_present = "permissions" in provides
client_present = "oidc_callback" in provides or "permissions" in requires

catalog_permissions_raw = provides.get("permissions") if catalog_present else None
client_permissions_raw = requires.get("permissions") if "permissions" in requires else None
oidc_callback_raw = provides.get("oidc_callback") if "oidc_callback" in provides else None

if catalog_present:
    catalog_permissions = validate_permissions_map(
        catalog_permissions_raw, "provides"
    )
else:
    catalog_permissions = None

if client_present:
    if "oidc_callback" not in provides:
        fail("Identity claim: client present but provides.oidc_callback is missing")
    if "permissions" not in requires:
        fail("Identity claim: client present but requires.permissions is missing")
    if not isinstance(oidc_callback_raw, str) or not oidc_callback_raw:
        fail("Identity claim: provides.oidc_callback must be a non-empty string")
    if not oidc_callback_raw.startswith("/"):
        fail("Identity claim: provides.oidc_callback must be a path starting with '/'")
    client_permissions = validate_permissions_map(client_permissions_raw, "requires")
else:
    client_permissions = None

claim_data_present = (catalog_present or client_present)
if claim_data_present:
    if identity is not True:
        fail(
            "Identity claim: Requires.identity must be exactly true when workload provides "
            "Identity permission data"
        )
elif identity is True:
    # identity==true but no catalog nor client keys.
    fail("Identity claim: identity true with neither catalog nor client keys")
else:
    # Non-identity workloads (no permission data) are accepted by this validator.
    sys.exit(0)

# API permission catalog validation.
if catalog_permissions is not None:
    validate_api_catalog_keys(catalog_permissions.keys())

# OIDC client validation.
if client_permissions is not None:
    validate_client_keys(client_permissions.keys())

sys.exit(0)
PY
}

# Environment-level Identity permissions catalog uniqueness + contract validation.
# Validates every manifest-bearing workload directory inside ENV_DIR that has both
# requires.json and provides.json (internal sources). External sources are skipped
# because their contracts are inside the Artifact (a zip/URI) rather than in-tree.
#
# Collectively enforces:
# - fail-closed per-workload Identity contract validation
# - permission-key uniqueness within the environment across all API catalogs
environment_identity_permission_catalogs_validate() {
  local env_dir="${1:?environment_identity_permission_catalogs_validate: ENV_DIR required}"
  command -v python3 >/dev/null || {
    echo "environment_identity_permission_catalogs_validate: python3 required" >&2
    return 1
  }

  python3 - "${env_dir}" <<'PY'
import json, os, sys

env_dir = sys.argv[1]

def fail(msg: str):
    raise SystemExit(msg)

def load_obj(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            obj = json.load(f)
    except Exception as e:
        fail(f"Identity env: failed to load JSON {path}: {e}")
    if not isinstance(obj, dict):
        fail(f"Identity env: {path} must be a JSON object")
    return obj

def validate_permissions_map(raw, path_label: str, allow_empty: bool = False):
    if not isinstance(raw, dict):
        fail(f"Identity env: {path_label}.permissions must be an object")
    if not allow_empty and raw == {}:
        fail(f"Identity env: {path_label}.permissions must be non-empty")
    out = {}
    for k, v in raw.items():
        if not isinstance(k, str) or not k:
            fail(f"Identity env: {path_label}.permissions keys must be non-empty strings")
        if not isinstance(v, str) or not v:
            fail(f"Identity env: {path_label}.permissions values must be non-empty strings")
        out[k] = v
    return out

def validate_api_catalog(wl_name: str, catalog_permissions: dict):
    marker_keys = []
    for k in catalog_permissions.keys():
        parts = k.split(":")
        if len(parts) != 2:
            fail(f"Identity env: API permission key must be single-colon: {k!r}")
        slug, perm = parts
        if not slug:
            fail(f"Identity env: API permission key slug must be non-empty: {k!r}")
        if perm == "api":
            marker_keys.append(k)

    if len(marker_keys) != 1:
        fail(
            f"Identity env: workload {wl_name!r}: API permission catalog must include exactly one "
            f"mandatory marker key `<workload-slug>:api` (got marker keys: {sorted(marker_keys)!r})"
        )

    workload_slug = marker_keys[0].split(":")[0]
    marker_key = f"{workload_slug}:api"

    for k in catalog_permissions.keys():
        parts = k.split(":")
        slug, perm = parts
        if slug != workload_slug:
            fail(
                f"Identity env: workload {wl_name!r}: API permission key must use the same workload-slug "
                f"as marker {marker_key!r}: {k!r}"
            )
        if not perm:
            fail(f"Identity env: API permission key perm part empty: {k!r}")

    return set(catalog_permissions.keys())

def validate_client_keys(client_permissions: dict):
    for k in client_permissions.keys():
        parts = k.split(":")
        if len(parts) != 2:
            fail(f"Identity env: client permission key must be single-colon: {k!r}")
        slug, perm = parts
        if not slug or not perm:
            fail(f"Identity env: client permission key slug/perm must be non-empty: {k!r}")

def validate_workload(wl_dir: str, wl_name: str):
    requires_path = os.path.join(wl_dir, "requires.json")
    provides_path = os.path.join(wl_dir, "provides.json")
    requires = load_obj(requires_path)
    provides = load_obj(provides_path)

    identity = requires.get("identity", None)
    catalog_present = "permissions" in provides
    client_present = "oidc_callback" in provides or "permissions" in requires

    if not (catalog_present or client_present):
        if identity is True:
            fail(f"Identity env: workload {wl_name!r}: identity true with neither catalog nor client keys")
        return []

    # If any permission data is present, identity must be exactly true.
    if identity is not True:
        fail(f"Identity env: workload {wl_name!r}: Requires.identity must be exactly true when workload provides Identity permission data")

    catalog_permissions = None
    if catalog_present:
        catalog_permissions = validate_permissions_map(
            provides["permissions"], "provides"
        )
    client_permissions = None
    if client_present:
        if "oidc_callback" not in provides:
            fail(f"Identity env: workload {wl_name!r}: client present but provides.oidc_callback is missing")
        if "permissions" not in requires:
            fail(f"Identity env: workload {wl_name!r}: client present but requires.permissions is missing")
        oidc_callback = provides.get("oidc_callback")
        if not isinstance(oidc_callback, str) or not oidc_callback:
            fail(f"Identity env: workload {wl_name!r}: provides.oidc_callback must be a non-empty string")
        if not oidc_callback.startswith("/"):
            fail(f"Identity env: workload {wl_name!r}: provides.oidc_callback must start with '/'")
        client_permissions = validate_permissions_map(
            requires["permissions"], "requires"
        )

    api_keys = set()
    if catalog_permissions is not None:
        validate_api_catalog(wl_name, catalog_permissions)
        api_keys = set(catalog_permissions.keys())

    if client_permissions is not None:
        validate_client_keys(client_permissions)

    return list(api_keys)

if not os.path.isdir(env_dir):
    fail(f"Identity env: ENV_DIR not a directory: {env_dir}")

seen = {}  # permission_key -> workload basename

for entry in sorted(os.listdir(env_dir)):
    if entry.startswith("."):
        continue
    wl_dir = os.path.join(env_dir, entry)
    if not os.path.isdir(wl_dir):
        continue
    if not os.path.isfile(os.path.join(wl_dir, "manifest.json")):
        continue
    requires_path = os.path.join(wl_dir, "requires.json")
    provides_path = os.path.join(wl_dir, "provides.json")
    # For non-internal sources, contract files are inside the Artifact, so skip
    # environment-level uniqueness (per-workload validation happens on Host after materialize).
    if not os.path.isfile(requires_path) or not os.path.isfile(provides_path):
        continue

    for key in validate_workload(wl_dir, entry):
        other = seen.get(key)
        if other is not None:
            fail(
                f"Identity env: permission key {key!r} appears in multiple workloads: {other!r} and {entry!r}"
            )
        seen[key] = entry

sys.exit(0)
PY
}
