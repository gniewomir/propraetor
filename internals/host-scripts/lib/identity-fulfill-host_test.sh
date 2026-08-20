#!/usr/bin/env bash
# Offline tests: Identity permission catalog + OIDC client gather + Pocket ID fulfill
# (ADR-0057 / #253 / #254). Stubs Pocket ID admin HTTP; does not talk to Pocket ID.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=identity-fulfill-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/identity-fulfill-host.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/identity-fulfill.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

HOME_DIR="${TMP}/home"
UNIT_DIR="${TMP}/units"
WORKLOADS_ROOT="${TMP}/workloads"
DATA_ROOT="${TMP}/data"
USER_NAME=""
ENV_SLUG=test
ADMIN_ENV="${DATA_ROOT}/admin/environment"
mkdir -p "${HOME_DIR}" "${UNIT_DIR}" "${DATA_ROOT}/admin"
printf 'STATIC_API_KEY=test-api-key-0123456789\n' >"${ADMIN_ENV}"

write_catalog_workload() {
  local name="$1"
  shift
  local -a perms=("$@")
  local dir="${WORKLOADS_ROOT}/${name}"
  mkdir -p "${dir}/systemd"
  printf '%s\n' '{"intent":"run","source":"internal"}' >"${dir}/manifest.json"
  printf '%s\n' '{"identity":true,"database":false,"cache":false}' >"${dir}/requires.json"
  python3 - "${dir}/provides.json" "${name}" "${perms[@]}" <<'PY'
import json, sys
name = sys.argv[2]
keys = sys.argv[3:]
permissions = {}
for item in keys:
    key, _, label = item.partition("=")
    permissions[key] = label or key
if f"{name}:api" not in permissions:
    permissions[f"{name}:api"] = "API"
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"permissions": permissions}, f)
    f.write("\n")
PY
  printf '[Container]\nImage=localhost/demo\n' >"${dir}/systemd/${name}.container"
}

write_client_workload() {
  local name="$1"
  shift
  local callback_path="${1:?write_client_workload: callback path required}"
  shift
  local -a perms=("$@")
  local dir="${WORKLOADS_ROOT}/${name}"
  mkdir -p "${dir}/systemd"
  printf '%s\n' '{"intent":"run","source":"internal"}' >"${dir}/manifest.json"
  python3 - "${dir}/requires.json" "${name}" "${perms[@]}" <<'PY'
import json, sys
keys = sys.argv[3:]
permissions = {}
for item in keys:
    key, _, label = item.partition("=")
    permissions[key] = label or key
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"identity": True, "database": False, "cache": False, "permissions": permissions}, f)
    f.write("\n")
PY
  python3 - "${dir}/provides.json" "${callback_path}" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"oidc_callback": sys.argv[2]}, f)
    f.write("\n")
PY
  cat >"${dir}/binding.json" <<'EOF'
{
  "domains": {
    "beta.example.test": [],
    "alpha.example.test": []
  },
  "environment": {}
}
EOF
  printf '[Container]\nImage=localhost/demo\n' >"${dir}/systemd/${name}.container"
}

# --- aud / merge ---
[[ "$(identity_resource_aud_for_slug test)" == "propreator:test" ]] \
  || fail "aud mapping"
write_catalog_workload alpha "alpha:api=API" "alpha:read=Read"
write_catalog_workload beta "beta:api=API" "beta:write=Write"
merged="$(identity_merge_catalog_permissions_json \
  <(printf 'alpha\nbeta\n') "${WORKLOADS_ROOT}")"
python3 - "${merged}" <<'PY'
import json, sys
perms = json.loads(sys.argv[1])
keys = {p["key"] for p in perms}
want = {"alpha:api", "alpha:read", "beta:api", "beta:write"}
if keys != want:
    raise SystemExit(f"merge keys want {want}, got {keys}")
PY
pass "permission catalog merge across workloads"

# --- claimant gating ---
write_catalog_workload claim-wl "claim-wl:api=API"
[[ "$(identity_catalog_workload_is_run_claimant "${WORKLOADS_ROOT}/claim-wl")" == "1" ]] \
  || fail "catalog claimant must claim"
printf '%s\n' '{"intent":"stop","source":"internal"}' \
  >"${WORKLOADS_ROOT}/claim-wl/manifest.json"
[[ "$(identity_catalog_workload_is_run_claimant "${WORKLOADS_ROOT}/claim-wl")" == "0" ]] \
  || fail "Intent stop must not claim"
pass "catalog claimant gated on Intent run + identity + permissions"

# --- Pocket ID admin stub ---
POCKET_ID_STATE="${TMP}/pocket-id-state.json"
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"apis": [], "clients": {}, "api_access": {}, "next_id": 1}, f)
PY

identity_pocket_id_discovery_issuer() {
  printf 'https://auth.example.test\n'
}

identity_pocket_id_admin_curl() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  python3 - "${POCKET_ID_STATE}" "${method}" "${path}" "${body}" <<'PY'
import json, sys, urllib.parse

state_path, method, path, body = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(state_path, encoding="utf-8") as f:
    state = json.load(f)

def find_api_by_resource(resource):
    for api in state["apis"]:
        if api.get("resource") == resource:
            return api
    return None

# Production list uses bare GET /api/apis (identity_pocket_id_api_list_all);
# setup readiness may still pass pagination query params.
if method == "GET" and (path == "/api/apis" or path.startswith("/api/apis?")):
    print(json.dumps({
        "data": [{"id": a["id"], "name": a["name"], "resource": a["resource"],
                  "permissions": a.get("permissions", [])} for a in state["apis"]],
        "pagination": {"totalPages": 1},
    }))
elif path == "/api/apis" and method == "POST":
    payload = json.loads(body)
    if find_api_by_resource(payload["resource"]):
        raise SystemExit(1)
    api_id = f"api-{state['next_id']}"
    state["next_id"] += 1
    api = {"id": api_id, "name": payload["name"], "resource": payload["resource"], "permissions": []}
    state["apis"].append(api)
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print(json.dumps(api))
elif "/permissions" in path and method == "PUT":
    api_id = path.split("/")[3]
    payload = json.loads(body)
    wanted = payload.get("permissions") or []
    for api in state["apis"]:
        if api["id"] != api_id:
            continue
        existing = {p["key"]: p for p in api.get("permissions") or []}
        new_perms = []
        for row in wanted:
            key = row["key"]
            if key in existing:
                perm = existing[key]
                perm["name"] = row["name"]
                new_perms.append(perm)
            else:
                perm_id = f"perm-{state['next_id']}"
                state["next_id"] += 1
                new_perms.append({"id": perm_id, "key": key, "name": row["name"]})
        api["permissions"] = new_perms
        with open(state_path, "w", encoding="utf-8") as f:
            json.dump(state, f)
        out = dict(api)
        print(json.dumps(out))
        break
    else:
        raise SystemExit(1)
elif method == "DELETE" and path.startswith("/api/apis/"):
    api_id = path.rsplit("/", 1)[-1]
    state["apis"] = [a for a in state["apis"] if a["id"] != api_id]
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print("")
elif path.startswith("/api/oidc/clients/") and method == "GET":
    client_id = path.rsplit("/", 1)[-1]
    client = state["clients"].get(client_id)
    if not client:
        raise SystemExit(1)
    print(json.dumps(client))
elif path == "/api/oidc/clients" and method == "POST":
    payload = json.loads(body)
    client_id = payload["id"]
    if client_id in state["clients"]:
        raise SystemExit(1)
    client = {
        "id": client_id,
        "name": payload["name"],
        "isPublic": payload.get("isPublic", False),
        "pkceEnabled": payload.get("pkceEnabled", False),
        "isGroupRestricted": payload.get("isGroupRestricted", False),
        "callbackURLs": payload.get("callbackURLs") or [],
    }
    state["clients"][client_id] = client
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print(json.dumps(client))
elif path.startswith("/api/oidc/clients/") and method == "PUT":
    client_id = path.rsplit("/", 1)[-1]
    if client_id not in state["clients"]:
        raise SystemExit(1)
    payload = json.loads(body)
    client = state["clients"][client_id]
    client.update({
        "name": payload["name"],
        "isPublic": payload.get("isPublic", False),
        "pkceEnabled": payload.get("pkceEnabled", False),
        "isGroupRestricted": payload.get("isGroupRestricted", False),
        "callbackURLs": payload.get("callbackURLs") or [],
    })
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print(json.dumps(client))
elif path.startswith("/api/oidc/clients/") and method == "DELETE":
    client_id = path.rsplit("/", 1)[-1]
    state["clients"].pop(client_id, None)
    state["api_access"].pop(client_id, None)
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print("")
elif path.startswith("/api/api-access/") and method == "PUT":
    client_id = path.rsplit("/", 1)[-1]
    payload = json.loads(body)
    state["api_access"][client_id] = payload
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f)
    print(json.dumps(payload))
else:
    raise SystemExit(f"unhandled stub request {method} {path}")
PY
}

write_catalog_workload api-one "api-one:api=API" "api-one:read=Read"
# Fulfill only the probe workload tree (isolate from merge/claimant fixtures above).
PROBE_ROOT="${TMP}/probe-workloads"
mkdir -p "${PROBE_ROOT}"
cp -a "${WORKLOADS_ROOT}/api-one" "${PROBE_ROOT}/"
identity_fulfill_declarations "${PROBE_ROOT}" test || fail "fulfill should succeed"

binding="$(workload_identity_binding_dir api-one)"
[[ -f "${binding}/resource-server.env" ]] || fail "expected resource-server.env"
grep -Fx 'IDENTITY_AUD=propreator:test' "${binding}/resource-server.env" >/dev/null \
  || fail "binding aud must be environment-scoped"
grep -Fx 'IDENTITY_ISSUER=https://auth.example.test' "${binding}/resource-server.env" >/dev/null \
  || fail "binding issuer missing"
grep -Fx 'IDENTITY_MARKER_KEY=api-one:api' "${binding}/resource-server.env" >/dev/null \
  || fail "binding must publish mandatory API marker permission key"
pass "published resource-server binding with environment aud"

python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
apis = [a for a in state["apis"] if a["resource"] == "propreator:test"]
if len(apis) != 1:
    raise SystemExit(f"expected one environment API, got {len(apis)}")
keys = {p["key"] for p in apis[0]["permissions"]}
if "api-one:api" not in keys:
    raise SystemExit("marker permission key missing on resource server")
PY
pass "Pocket ID API created with marker permission key"

# Full-replace: drop api-one:read on redeploy with fewer keys.
write_catalog_workload api-one "api-one:api=API"
rm -rf "${PROBE_ROOT}/api-one"
cp -a "${WORKLOADS_ROOT}/api-one" "${PROBE_ROOT}/"
identity_fulfill_declarations "${PROBE_ROOT}" test || fail "re-fulfill should succeed"
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
api = next(a for a in state["apis"] if a["resource"] == "propreator:test")
keys = {p["key"] for p in api["permissions"]}
if keys != {"api-one:api"}:
    raise SystemExit(f"full-replace want only marker, got {keys}")
PY
pass "full-replace drops permissions not declared anymore"

# Zero catalog declarants in SoT deletes environment API on Orphan Reap projection (#256).
rm -rf "${PROBE_ROOT}/api-one"
identity_drop_absent_fulfillments "${PROBE_ROOT}" test || fail "orphan drop should succeed"
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
if any(a["resource"] == "propreator:test" for a in state["apis"]):
    raise SystemExit("environment API should be deleted when no catalog declarants remain in SoT")
PY
pass "Orphan Reap projection deletes environment-scoped API with zero catalog declarants"

# Intent stop unpublishes catalog binding but leaves Pocket ID permissions (#256).
write_catalog_workload stop-api "stop-api:api=API" "stop-api:read=Read"
STOP_ROOT="${TMP}/stop-workloads"
mkdir -p "${STOP_ROOT}"
cp -a "${WORKLOADS_ROOT}/stop-api" "${STOP_ROOT}/"
identity_fulfill_declarations "${STOP_ROOT}" test || fail "stop-api fulfill should succeed"
stop_binding="$(workload_identity_binding_dir stop-api)/resource-server.env"
[[ -f "${stop_binding}" ]] || fail "expected resource-server binding for run catalog claimant"
printf '%s\n' '{"intent":"stop","source":"internal"}' >"${STOP_ROOT}/stop-api/manifest.json"
identity_fulfill_declarations "${STOP_ROOT}" test || fail "intent stop fulfill should succeed"
[[ ! -f "${stop_binding}" ]] || fail "Intent stop must unpublish catalog resource-server binding"
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
api = next((a for a in state["apis"] if a["resource"] == "propreator:test"), None)
if not api:
    raise SystemExit("Intent stop must leave Environment-scoped Pocket ID API interior record")
keys = {p["key"] for p in api.get("permissions") or []}
if "stop-api:api" not in keys or "stop-api:read" not in keys:
    raise SystemExit(f"Intent stop must retain catalog permissions; keys={sorted(keys)}")
PY
pass "Intent stop unpublishes catalog binding and leaves Pocket ID permissions"

# Orphan Reap drops OIDC client interior when Workload basename disappears (#256).
write_catalog_workload orphan-api "orphan-api:api=API"
write_client_workload orphan-spa "/oauth/callback" "orphan-api:api=API"
ORPHAN_ROOT="${TMP}/orphan-workloads"
mkdir -p "${ORPHAN_ROOT}"
cp -a "${WORKLOADS_ROOT}/orphan-api" "${WORKLOADS_ROOT}/orphan-spa" "${ORPHAN_ROOT}/"
identity_fulfill_declarations "${ORPHAN_ROOT}" test || fail "orphan fixtures fulfill should succeed"
rm -rf "${ORPHAN_ROOT}/orphan-spa"
identity_drop_absent_fulfillments "${ORPHAN_ROOT}" test || fail "orphan drop should succeed"
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
if "orphan-spa" in state["clients"]:
    raise SystemExit("Orphan Reap must delete Pocket ID OIDC client interior record")
if state["api_access"].get("orphan-spa"):
    raise SystemExit("Orphan Reap must drop api-access grants for orphan OIDC client")
api = next(a for a in state["apis"] if a["resource"] == "propreator:test")
keys = {p["key"] for p in api.get("permissions") or []}
if "orphan-api:api" not in keys:
    raise SystemExit("retained catalog declarants must keep their permissions after orphan client drop")
PY
pass "Orphan Reap deletes OIDC client interior and prunes orphan grants"

# --- OIDC client gather (#254) ---
write_catalog_workload svc-a "svc-a:api=API" "svc-a:read=Read"
write_catalog_workload svc-b "svc-b:api=API" "svc-b:write=Write"
write_client_workload my-spa "/oauth/callback" \
  "svc-a:api=API" "svc-a:read=Read" "svc-b:api=API" "svc-b:write=Write"

CLIENT_ROOT="${TMP}/client-workloads"
mkdir -p "${CLIENT_ROOT}"
cp -a "${WORKLOADS_ROOT}/svc-a" "${WORKLOADS_ROOT}/svc-b" "${WORKLOADS_ROOT}/my-spa" \
  "${CLIENT_ROOT}/"

[[ "$(identity_client_workload_is_run_claimant "${CLIENT_ROOT}/my-spa")" == "1" ]] \
  || fail "client run claimant"
callbacks="$(identity_client_callback_urls_json "${CLIENT_ROOT}/my-spa")"
python3 - "${callbacks}" <<'PY'
import json, sys
urls = json.loads(sys.argv[1])
want = [
    "https://alpha.example.test/oauth/callback",
    "https://beta.example.test/oauth/callback",
]
if urls != want:
    raise SystemExit(f"callback URLs want {want}, got {urls}")
PY
pass "callback registration deterministic from Binding FQDNs + oidc_callback path"

identity_fulfill_declarations "${CLIENT_ROOT}" test || fail "client fulfill should succeed"

python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
client = state["clients"].get("my-spa")
if not client:
    raise SystemExit("OIDC client must be registered by Workload basename")
if client["id"] != "my-spa":
    raise SystemExit(f"client id must be basename, got {client['id']!r}")
if not client.get("isPublic"):
    raise SystemExit("client must be public")
if not client.get("pkceEnabled"):
    raise SystemExit("client must require PKCE")
if client.get("callbackURLs") != [
    "https://alpha.example.test/oauth/callback",
    "https://beta.example.test/oauth/callback",
]:
    raise SystemExit(f"unexpected callbackURLs: {client.get('callbackURLs')}")
access = state["api_access"].get("my-spa") or {}
perm_ids = access.get("userDelegatedPermissionIds") or []
api = next(a for a in state["apis"] if a["resource"] == "propreator:test")
by_key = {p["key"]: p["id"] for p in api["permissions"]}
want_keys = ["svc-a:api", "svc-a:read", "svc-b:api", "svc-b:write"]
if sorted(perm_ids) != sorted(by_key[k] for k in want_keys):
    raise SystemExit("api-access must grant all requested permission keys across APIs")
PY
pass "OIDC client registered by basename with multi-API api-access grants"

client_binding="$(workload_identity_binding_dir my-spa)/client.env"
[[ -f "${client_binding}" ]] || fail "expected client.env binding"
grep -Fx 'IDENTITY_CLIENT_ID=my-spa' "${client_binding}" >/dev/null || fail "client id binding"
grep -Fx 'IDENTITY_RESOURCE=propreator:test' "${client_binding}" >/dev/null || fail "resource binding"
grep -Fx 'IDENTITY_SCOPE=svc-a:api svc-a:read svc-b:api svc-b:write' "${client_binding}" >/dev/null \
  || fail "scope binding must list gathered permission keys"
grep -Fx 'IDENTITY_CALLBACK_URLS=https://alpha.example.test/oauth/callback https://beta.example.test/oauth/callback' \
  "${client_binding}" >/dev/null || fail "callback URL binding"
pass "published OIDC client binding with scope across multiple APIs"

# Intent stop unpublishes client binding but leaves Pocket ID client.
printf '%s\n' '{"intent":"stop","source":"internal"}' >"${CLIENT_ROOT}/my-spa/manifest.json"
identity_fulfill_declarations "${CLIENT_ROOT}" test || fail "intent stop fulfill should succeed"
[[ ! -f "${client_binding}" ]] || fail "Intent stop must unpublish client binding"
python3 - "${POCKET_ID_STATE}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    state = json.load(f)
if "my-spa" not in state["clients"]:
    raise SystemExit("Intent stop must leave Pocket ID OIDC client interior record")
PY
pass "Intent stop unpublishes client binding and leaves Pocket ID client"

echo "All identity-fulfill-host offline tests passed."
