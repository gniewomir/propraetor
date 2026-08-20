#!/usr/bin/env bash
# Acceptance Test: Identity OIDC client gather + multi-API grants (#254).
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
ROUTE_FQDN="$(acceptance_route_fqdn)" \
  || fail "Domain want-list must provide a route FQDN for OIDC client Binding"

FIX_DIR="$(acceptance_env_dir)"
mkdir -p "${FIX_DIR}"
API_A=idapi-a
API_B=idapi-b
SPA=idspa
acceptance_wl_track "${API_A}"
acceptance_wl_track "${API_B}"
acceptance_wl_track "${SPA}"
trap 'acceptance_wl_cleanup' EXIT

host_ssh \
  "rm -rf /host-volume/workloads/${API_A} /host-volume/workloads/${API_B} /host-volume/workloads/${SPA} \
          /home/platform/.config/platform/workloads/${API_A} \
          /home/platform/.config/platform/workloads/${API_B} \
          /home/platform/.config/platform/workloads/${SPA}" \
  || true

for wl in "${API_A}" "${API_B}"; do
  mkdir -p "${FIX_DIR}/${wl}/systemd"
  cat >"${FIX_DIR}/${wl}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal",
  "description": "Identity API catalog for OIDC client probe"
}
EOF
  cat >"${FIX_DIR}/${wl}/systemd/${wl}.container" <<EOF
[Unit]
Description=Identity API catalog probe ${wl}

[Container]
Image=docker.io/library/busybox:1.36
ContainerName=${wl}
Network=service-network.network
Entrypoint=/bin/sleep
Exec=infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
EOF
done
# Distinct permission shapes across APIs (matches unit gather fixture).
acceptance_write_identity_api_catalog_claim "${FIX_DIR}/${API_A}" "${API_A}" \
  "${API_A}:api=API access" \
  "${API_A}:read=Read access"
acceptance_write_identity_api_catalog_claim "${FIX_DIR}/${API_B}" "${API_B}" \
  "${API_B}:api=API access" \
  "${API_B}:write=Write access"

mkdir -p "${FIX_DIR}/${SPA}/systemd"
cat >"${FIX_DIR}/${SPA}/manifest.json" <<EOF
{
  "intent": "run",
  "source": "internal",
  "description": "Identity OIDC client probe"
}
EOF
acceptance_write_identity_oidc_client_claim "${FIX_DIR}/${SPA}" "/oauth/callback" \
  "${API_A}:api=API access" \
  "${API_A}:read=Read access" \
  "${API_B}:api=API access" \
  "${API_B}:write=Write access"
cat >"${FIX_DIR}/${SPA}/binding.json" <<EOF
{
  "domains": {
    "${ROUTE_FQDN}": []
  },
  "environment": {}
}
EOF
cat >"${FIX_DIR}/${SPA}/systemd/${SPA}.container" <<EOF
[Unit]
Description=Identity OIDC client probe

[Container]
Image=docker.io/library/busybox:1.36
ContainerName=${SPA}
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

client_binding="/home/platform/.config/platform/workloads/${SPA}/identity/client.env"
host_ssh "test -f '${client_binding}'" \
  || fail "expected published Identity OIDC client binding"
host_ssh "grep -Fx 'IDENTITY_CLIENT_ID=${SPA}' '${client_binding}'" \
  || fail "published binding client_id must be Workload basename"
host_ssh "grep -Fx 'IDENTITY_RESOURCE=${RESOURCE}' '${client_binding}'" \
  || fail "published binding resource must match environment-scoped aud"
host_ssh "grep -Fx 'IDENTITY_CALLBACK_URLS=https://${ROUTE_FQDN}/oauth/callback' '${client_binding}'" \
  || fail "published callback URL must be deterministic from Binding FQDN + oidc_callback"
host_ssh "grep -Fx 'IDENTITY_SCOPE=${API_A}:api ${API_A}:read ${API_B}:api ${API_B}:write' '${client_binding}'" \
  || fail "published scope must include all requested permission keys across APIs"
pass "Identity OIDC client received binding with multi-API scope and deterministic callback URL"

api_key_line="$(host_ssh "grep -E '^STATIC_API_KEY=' /host-volume/components/identity/persist/admin/environment | head -n1")"
[[ -n "${api_key_line}" ]] || fail "Identity admin STATIC_API_KEY missing on Host"
api_key="${api_key_line#STATIC_API_KEY=}"

client_json="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u platform)
HOME_DIR=\$(getent passwd platform | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u platform -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman run --rm --network service-network \
    docker.io/curlimages/curl:8.12.1 \
    curl -fsS -H "X-API-Key: ${api_key}" \
    "http://identity:1411/api/oidc/clients/${SPA}"'
REMOTE
)"
python3 - "${SPA}" "${ROUTE_FQDN}" "${client_json}" <<'PY'
import json, sys
spa, fqdn, payload_raw = sys.argv[1], sys.argv[2], sys.argv[3]
client = json.loads(payload_raw)
if client.get("id") != spa:
    raise SystemExit(f"client id must be basename {spa!r}, got {client.get('id')!r}")
if not client.get("isPublic"):
    raise SystemExit("Setup-owned client must be public")
if not client.get("pkceEnabled"):
    raise SystemExit("Setup-owned client must require PKCE")
want_cb = [f"https://{fqdn}/oauth/callback"]
if client.get("callbackURLs") != want_cb:
    raise SystemExit(f"callbackURLs want {want_cb}, got {client.get('callbackURLs')!r}")
PY
pass "Pocket ID OIDC client registered by Workload basename with deterministic callback URLs"
