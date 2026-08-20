#!/usr/bin/env bash
# Acceptance Test: Identity Intent stop + Orphan Reap lifecycle (#256 / ADR-0057).
# Intent stop unpublishes bindings while minted tokens authorize until exp;
# Orphan Reap + post-workloads drops interior Pocket ID objects for absent basenames.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

ENV_SLUG="${PLATFORM_ENV:-test}"
# shellcheck source=../../lib/identity/identity-config.sh
source "${REPO_ROOT}/internals/lib/identity/identity-config.sh"
# shellcheck source=../../lib/identity/identity-resource.sh
source "${REPO_ROOT}/internals/lib/identity/identity-resource.sh"
identity_config_issuer_fqdn_for "${ENV_SLUG}" >/dev/null \
  || fail "committed identity.json must validate for Environment ${ENV_SLUG}"
RESOURCE="$(identity_resource_aud_for_slug "${ENV_SLUG}")" \
  || fail "resource aud mapping failed"
ROUTE_FQDN="$(acceptance_route_fqdn)" \
  || fail "Domain want-list must provide a route FQDN for API auth probe"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=idlcstop
KEEP=idlckeep
acceptance_wl_track "${WL}" "${KEEP}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh bash -s <<REMOTE
set -euo pipefail
for n in ${WL} ${KEEP}; do
  rm -rf "/host-volume/workloads/\${n}" \
         "/home/platform/.config/platform/workloads/\${n}"
done
REMOTE

stage_wl() {
  local name="$1"
  local with_route="${2:-yes}"
  mkdir -p "${FIX_DIR}/${name}/systemd"
  cat >"${FIX_DIR}/${name}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal",
  "description": "Identity lifecycle probe ${name}"
}
EOF
  if [[ "${with_route}" == "yes" ]]; then
    mkdir -p "${FIX_DIR}/${name}/routes"
    acceptance_write_identity_api_auth_probe "${FIX_DIR}/${name}" "${name}"
    cat >"${FIX_DIR}/${name}/binding.json" <<EOF
{
  "domains": {
    "${ROUTE_FQDN}": ["routes/api.conf.example"]
  },
  "environment": {}
}
EOF
    cat >"${FIX_DIR}/${name}/routes/api.conf.example" <<EOF
location / {
    proxy_pass http://${name}:8080;
}
EOF
    cat >"${FIX_DIR}/${name}/systemd/${name}.pod" <<EOF
[Unit]
Description=Identity lifecycle probe pod ${name}

[Pod]
Network=service-network.network
NetworkAlias=${name}

[Install]
WantedBy=default.target
EOF
    cat >"${FIX_DIR}/${name}/systemd/${name}-api.container" <<EOF
[Unit]
Description=Identity lifecycle probe server ${name}

[Container]
Image=docker.io/library/python:3.12-alpine
ContainerName=${name}-api
Pod=${name}.pod
Volume=../app:/app:ro
Environment=LISTEN_HOST=0.0.0.0
Environment=LISTEN_PORT=8080
Exec=sh -c "pip install -q -r /app/requirements.txt && exec python /app/server.py"

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  else
    acceptance_write_identity_api_catalog_claim "${FIX_DIR}/${name}" "${name}"
    cat >"${FIX_DIR}/${name}/systemd/${name}.container" <<EOF
[Unit]
Description=Identity lifecycle peer catalog ${name}

[Container]
Image=docker.io/library/busybox:1.36
ContainerName=${name}
Network=service-network.network
Entrypoint=/bin/sleep
Exec=infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  fi
}

stage_wl "${WL}" yes
stage_wl "${KEEP}" no

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
"${REPO_ROOT}/internals/ensure-workload.sh" "${KEEP}" --env "${ENV_SLUG}"
ensure_identity_fulfillment
ensure_edge_route_fulfillment

binding_env="/home/platform/.config/platform/workloads/${WL}/identity/resource-server.env"
host_ssh "test -f '${binding_env}'" \
  || fail "expected published Identity resource-server binding"
pass "Identity catalog claimant received resource-server binding"

host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user restart ${WL}-pod.service ${WL}-api.service ${KEEP}.service
REMOTE

wait_active() {
  local unit="$1"
  local state=""
  local _
  for _ in $(seq 1 120); do
    state="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p ActiveState --value ${unit} 2>/dev/null || echo ""
REMOTE
)"
    [[ "${state}" == "active" ]] && return 0
    sleep 2
  done
  return 1
}

wait_active "${WL}-api.service" || fail "lifecycle probe API must become active"
acceptance_wait_user_unit_active edge-nginx.service 60 \
  || fail "Edge nginx must be active before HTTPS API probes"

api_key_line="$(host_ssh "grep -E '^STATIC_API_KEY=' /host-volume/components/identity/persist/admin/environment | head -n1")"
[[ -n "${api_key_line}" ]] || fail "Identity admin STATIC_API_KEY missing on Host"
api_key="${api_key_line#STATIC_API_KEY=}"

extract_access_token() {
  python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])"
}

token_before_stop="$(
  acceptance_identity_mint_token "${WL}:api" "${RESOURCE}" "${WL}:api" "${api_key}" \
    "acceptance-${WL}-probe" | extract_access_token
)"
[[ -n "${token_before_stop}" ]] || fail "token mint before Intent stop failed"

code_before_stop=""
for _ in $(seq 1 30); do
  code_before_stop="$(curl -skS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
    --resolve "${ROUTE_FQDN}:443:${IP}" \
    -H "Authorization: Bearer ${token_before_stop}" \
    "https://${ROUTE_FQDN}/" 2>/dev/null || true)"
  [[ "${code_before_stop}" == "200" ]] && break
  sleep 1
done
[[ "${code_before_stop}" == "200" ]] \
  || fail "token must authorize API before Intent stop (code='${code_before_stop}')"
pass "minted token authorizes API while Workload Intent is run"

cat >"${FIX_DIR}/${WL}/manifest.json" <<EOF
{
  "intent": "stop",
  "source": "internal",
  "description": "Identity lifecycle probe ${WL}"
}
EOF
"${REPO_ROOT}/internals/ensure-workload.sh" "${WL}" --env "${ENV_SLUG}"
ensure_identity_fulfillment

host_ssh "test ! -f '${binding_env}'" \
  || fail "Component Setup must unpublish resource-server binding on Intent stop"
pass "Intent stop unpublishes Identity resource-server binding"

api_json="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman run --rm --network service-network \
    docker.io/curlimages/curl:8.12.1 \
    curl -fsS -H "X-API-Key: ${api_key}" \
    "http://identity:1411/api/apis?pagination[limit]=100"'
REMOTE
)"
python3 - "${RESOURCE}" "${WL}" "${api_json}" <<'PY'
import json, sys
resource, wl, payload_raw = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.loads(payload_raw)
match = [a for a in payload.get("data") or [] if a.get("resource") == resource]
if len(match) != 1:
    raise SystemExit(f"expected one Pocket ID API for {resource!r}, got {len(match)}")
keys = {p.get("key") for p in match[0].get("permissions") or []}
marker = f"{wl}:api"
if marker not in keys:
    raise SystemExit(f"Intent stop must retain marker permission {marker!r}; keys={sorted(keys)}")
PY
pass "Intent stop leaves Pocket ID catalog permissions intact"

python3 - "${token_before_stop}" "${RESOURCE}" "${WL}" <<'PY'
import base64, json, sys, time

token, resource, wl = sys.argv[1], sys.argv[2], sys.argv[3]
marker = f"{wl}:api"
parts = token.split(".")
if len(parts) < 2:
    raise SystemExit("access_token is not a JWT")
pad = "=" * (-len(parts[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(parts[1] + pad))
exp = claims.get("exp")
if not isinstance(exp, int) or exp <= int(time.time()):
    raise SystemExit(f"token must remain valid until exp; exp={exp!r}")
aud = claims.get("aud")
aud_ok = resource in aud if isinstance(aud, list) else aud == resource
if not aud_ok:
    raise SystemExit(f"JWT aud must still include {resource!r}, got {aud!r}")
scope_raw = claims.get("scope") or claims.get("scp") or ""
scopes = set(scope_raw.split()) if isinstance(scope_raw, str) else set(scope_raw)
if marker not in scopes:
    raise SystemExit(f"JWT scope must still include marker {marker!r}, got {sorted(scopes)}")
PY
pass "minted token remains valid after Intent stop (not revoked until exp)"

# Orphan Reap: drop stop candidate from Environment; interior drops on post-workloads.
rm -rf "${FIX_DIR:?}/${WL}"
"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
host_ssh "test -f /host-volume/workloads/${WL}/manifest.json" \
  || fail "Mirror must leave orphan SoT alone before Orphan Reap"

"${REPO_ROOT}/internals/purge-orphans.sh" --env "${ENV_SLUG}"
host_ssh "test ! -e /host-volume/workloads/${WL}" \
  || fail "Orphan Reap must remove orphan SoT"

perm_before_post="$(python3 - "${RESOURCE}" "${WL}" "${api_json}" <<'PY'
import json, sys
resource, wl, payload_raw = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.loads(payload_raw)
match = next(a for a in payload.get("data") or [] if a.get("resource") == resource)
keys = {p.get("key") for p in match.get("permissions") or []}
print("yes" if f"{wl}:api" in keys else "no")
PY
)"
[[ "${perm_before_post}" == "yes" ]] \
  || fail "Orphan Reap alone must not drop Pocket ID permissions for orphan basename"
pass "Orphan Reap alone leaves Pocket ID interior until post-workloads"

ensure_identity_post_workloads

api_json_after="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman run --rm --network service-network \
    docker.io/curlimages/curl:8.12.1 \
    curl -fsS -H "X-API-Key: ${api_key}" \
    "http://identity:1411/api/apis?pagination[limit]=100"'
REMOTE
)"
python3 - "${RESOURCE}" "${WL}" "${KEEP}" "${api_json_after}" <<'PY'
import json, sys
resource, orphan, keep, payload_raw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
payload = json.loads(payload_raw)
match = [a for a in payload.get("data") or [] if a.get("resource") == resource]
if len(match) != 1:
    raise SystemExit(f"expected retained Environment API, got {len(match)}")
keys = {p.get("key") for p in match[0].get("permissions") or []}
if f"{orphan}:api" in keys:
    raise SystemExit(f"post-workloads must drop orphan permissions; keys={sorted(keys)}")
if f"{keep}:api" not in keys:
    raise SystemExit(f"post-workloads must retain keep Workload permissions; keys={sorted(keys)}")
PY
pass "post-workloads prunes orphan catalog permissions and retains peer API"
