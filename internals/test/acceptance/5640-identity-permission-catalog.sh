#!/usr/bin/env bash
# Acceptance Test: Identity API permission catalog → Pocket ID aud + token scope (#253).
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
ISSUER_FQDN="$(identity_config_issuer_fqdn_for "${ENV_SLUG}")" \
  || fail "committed identity.json must validate for Environment ${ENV_SLUG}"
RESOURCE="$(identity_resource_aud_for_slug "${ENV_SLUG}")" \
  || fail "resource aud mapping failed"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
WL=idcatalog
acceptance_wl_track "${WL}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /host-volume/workloads/${WL} \
          /home/platform/.config/platform/workloads/${WL}" \
  || true

mkdir -p "${FIX_DIR}/${WL}/systemd"
cat >"${FIX_DIR}/${WL}/manifest.json" <<'EOF'
{
  "intent": "run",
  "source": "internal",
  "description": "Identity permission catalog probe"
}
EOF
acceptance_write_identity_api_catalog_claim "${FIX_DIR}/${WL}" "${WL}"
cat >"${FIX_DIR}/${WL}/systemd/${WL}.container" <<EOF
[Unit]
Description=Identity catalog probe

[Container]
Image=docker.io/library/busybox:1.36
ContainerName=${WL}
Network=service-network.network
Entrypoint=/bin/sleep
Exec=infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF

"${REPO_ROOT}/internals/ensure-mirror.sh" --env "${ENV_SLUG}"
ensure_identity_fulfillment

binding_env="/home/platform/.config/platform/workloads/${WL}/identity/resource-server.env"
host_ssh "test -f '${binding_env}'" \
  || fail "expected published Identity resource-server binding"
host_ssh "grep -Fx 'IDENTITY_AUD=${RESOURCE}' '${binding_env}'" \
  || fail "published binding aud must match environment-scoped resource"
host_ssh "grep -Fx 'IDENTITY_ISSUER=https://${ISSUER_FQDN}' '${binding_env}'" \
  || fail "published binding issuer must match identity.json FQDN"
pass "Identity catalog claimant received resource-server binding with environment aud"

api_key_line="$(host_ssh "grep -E '^STATIC_API_KEY=' /host-volume/components/identity/persist/admin/environment | head -n1")"
[[ -n "${api_key_line}" ]] || fail "Identity admin STATIC_API_KEY missing on Host"
api_key="${api_key_line#STATIC_API_KEY=}"

api_json=""
for _ in $(seq 1 30); do
  api_json="$(host_ssh bash -s <<REMOTE 2>/dev/null || true
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman run --rm --network service-network \
    docker.io/curlimages/curl:8.12.1 \
    curl -sS --connect-timeout 2 --max-time 10 \
      -H "X-API-Key: ${api_key}" \
      "http://identity:1411/api/apis" || true'
REMOTE
  )" || true
  if printf '%s\n' "${api_json}" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

[[ -n "${api_json}" ]] || fail "Pocket ID admin /api/apis returned empty body"
if ! printf '%s\n' "${api_json}" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  fail "Pocket ID admin /api/apis returned non-JSON body: ${api_json}"
fi
printf '%s\n' "${api_json}" | python3 - "${RESOURCE}" "${WL}" <<'PY'
import json, sys
resource, wl = sys.argv[1], sys.argv[2]
payload = json.loads(sys.stdin.read())
match = [a for a in payload.get("data") or [] if a.get("resource") == resource]
if len(match) != 1:
    raise SystemExit(f"expected one Pocket ID API for {resource!r}, got {len(match)}")
keys = {p.get("key") for p in match[0].get("permissions") or []}
marker = f"{wl}:api"
if marker not in keys:
    raise SystemExit(f"marker permission {marker!r} missing from resource server; keys={sorted(keys)}")
PY
pass "Pocket ID resource server has environment aud and API marker permission key"

# Mint a client-credentials access token with the marker scope; verify JWT aud + scope.
token_json="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
API_KEY='${api_key}'
RESOURCE='${RESOURCE}'
WL='${WL}'
MARKER="\${WL}:api"
CLIENT='acceptance-idcatalog-probe'
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c '
set -euo pipefail
cd "$HOME"
curl_json() {
  podman run --rm --network service-network docker.io/curlimages/curl:8.12.1 \
    curl -sS --connect-timeout 2 --max-time 10 \
      -H "X-API-Key: ${api_key}" -H "Content-Type: application/json" "$@"
}
# Ephemeral confidential client for token probe (Setup-owned clients are a separate story).
if ! curl_json "http://identity:1411/api/oidc/clients/${CLIENT}" >/dev/null 2>&1; then
  curl_json -X POST http://identity:1411/api/oidc/clients \
    -d "{\"id\":\"${CLIENT}\",\"name\":\"Acceptance probe\",\"isPublic\":false,\"isGroupRestricted\":false,\"callbackURLs\":[],\"logoutCallbackURLs\":[]}" >/dev/null
fi

SECRET=""
for _ in $(seq 1 30); do
  secret_json="$(curl_json -X POST "http://identity:1411/api/oidc/clients/${CLIENT}/secret" 2>/dev/null || true)"
  SECRET="$(printf '%s\n' "${secret_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])' 2>/dev/null || true)"
  [[ -n "${SECRET}" ]] && break
  sleep 1
done
[[ -n "${SECRET}" ]] || { echo "token stage: Pocket ID admin /secret returned empty/non-JSON" >&2; exit 1; }

api_json_retry=""
for _ in $(seq 1 30); do
  api_json_retry="$(curl_json "http://identity:1411/api/apis" 2>/dev/null || true)"
  if printf '%s\n' "${api_json_retry}" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
[[ -n "${api_json_retry}" ]] || { echo "token stage: Pocket ID admin /api/apis returned empty body" >&2; exit 1; }
if ! printf '%s\n' "${api_json_retry}" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  echo "token stage: Pocket ID admin /api/apis returned non-JSON body" >&2
  exit 1
fi
API_JSON="${api_json_retry}"
PERM_ID=$(printf "%s" "$API_JSON" | python3 -c "import json,sys; r=sys.argv[1]; wl=sys.argv[2]; d=json.load(sys.stdin); api=next(a for a in d[\"data\"] if a[\"resource\"]==r); print(next(p[\"id\"] for p in api[\"permissions\"] if p[\"key\"]==f\"{wl}:api\"))" "$RESOURCE" "$WL")
curl_json -X PUT "http://identity:1411/api/api-access/${CLIENT}" \
  -d "{\"userDelegatedPermissionIds\":[\"$PERM_ID\"],\"clientPermissionIds\":[\"$PERM_ID\"]}" >/dev/null
token_json_retry=""
for _ in $(seq 1 30); do
  token_json_retry="$(podman run --rm --network service-network docker.io/curlimages/curl:8.12.1 \
    curl -sS --connect-timeout 2 --max-time 10 -X POST http://identity:1411/api/oidc/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${CLIENT}" \
    --data-urlencode "client_secret=${SECRET}" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "resource=${RESOURCE}" \
    --data-urlencode "scope=${MARKER}" 2>/dev/null || true)"
  if printf '%s\n' "${token_json_retry}" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("access_token") else 1)' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
[[ -n "${token_json_retry}" ]] || { echo "token stage: /token returned empty response" >&2; exit 1; }
printf '%s\n' "${token_json_retry}"
'
REMOTE
)"
printf '%s\n' "${token_json}" | python3 - "${RESOURCE}" "${WL}" <<'PY'
import base64, json, sys

resource, wl = sys.argv[1], sys.argv[2]
marker = f"{wl}:api"
payload = json.loads(sys.stdin.read())
token = payload.get("access_token")
if not token:
    raise SystemExit("token response missing access_token")
parts = token.split(".")
if len(parts) < 2:
    raise SystemExit("access_token is not a JWT")
pad = "=" * (-len(parts[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(parts[1] + pad))
aud = claims.get("aud")
if isinstance(aud, list):
    aud_ok = resource in aud
else:
    aud_ok = aud == resource
if not aud_ok:
    raise SystemExit(f"JWT aud must include {resource!r}, got {aud!r}")
scope_raw = claims.get("scope") or claims.get("scp") or ""
if isinstance(scope_raw, list):
    scopes = set(scope_raw)
else:
    scopes = set(str(scope_raw).split())
if marker not in scopes:
    raise SystemExit(f"JWT scope must include marker {marker!r}, got {sorted(scopes)}")
PY
pass "issued access token aud matches environment resource and scope includes API marker key"
