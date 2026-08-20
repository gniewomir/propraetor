#!/usr/bin/env bash
# Pocket ID admin HTTP client for Identity Component Setup (ADR-0057 / #253).
# Sourced by identity-fulfill-host.sh. Override identity_pocket_id_admin_curl in
# offline tests to stub responses.
#
# Ambient: ADMIN_ENV, HOME_DIR, USER_NAME (for default curl via Service Network).
#
# Public:
#   identity_pocket_id_admin_api_key_from_env ENV_PATH
#   identity_pocket_id_admin_curl METHOD PATH [BODY]
#   identity_pocket_id_api_list_all
#   identity_pocket_id_api_find_by_resource RESOURCE
#   identity_pocket_id_api_create NAME RESOURCE
#   identity_pocket_id_api_update_permissions API_ID PERMISSIONS_JSON
#   identity_pocket_id_api_delete API_ID
#   identity_pocket_id_api_access_put CLIENT_ID PERMISSION_IDS_JSON
#   identity_pocket_id_oidc_client_create CLIENT_ID NAME IS_PUBLIC CALLBACK_URLS_JSON
#   identity_pocket_id_oidc_client_get CLIENT_ID
#   identity_pocket_id_oidc_client_update CLIENT_ID NAME IS_PUBLIC CALLBACK_URLS_JSON
#   identity_pocket_id_oidc_client_delete CLIENT_ID
#   identity_pocket_id_oidc_client_secret_create CLIENT_ID
#   identity_pocket_id_token_client_credentials CLIENT_ID CLIENT_SECRET RESOURCE SCOPE
#   identity_pocket_id_discovery_issuer

_identity_pocket_id_admin_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=quadlet-user-session.sh
source "${_identity_pocket_id_admin_lib_dir}/quadlet-user-session.sh"

_identity_resource_lib="${_identity_pocket_id_admin_lib_dir}/../../lib/identity/identity-resource.sh"
if [[ ! -f "${_identity_resource_lib}" ]]; then
  _identity_resource_lib="${_identity_pocket_id_admin_lib_dir}/identity-resource.sh"
fi
# shellcheck source=../../lib/identity/identity-resource.sh
source "${_identity_resource_lib}"

identity_pocket_id_admin_api_key_from_env() {
  local env_path="${1:?identity_pocket_id_admin_api_key_from_env: env path required}"
  local key=""
  [[ -f "${env_path}" ]] || {
    echo "identity_pocket_id_admin_api_key_from_env: missing ${env_path}" >&2
    return 1
  }
  key="$(grep -E '^STATIC_API_KEY=' "${env_path}" | head -n1 | cut -d= -f2- || true)"
  [[ -n "${key}" ]] || {
    echo "identity_pocket_id_admin_api_key_from_env: STATIC_API_KEY missing in ${env_path}" >&2
    return 1
  }
  printf '%s\n' "${key}"
}

# Default: curl Pocket ID on Service Network dial name identity.
# Prints response body to stdout; returns non-zero on HTTP >= 400.
identity_pocket_id_admin_curl() {
  local method="${1:?identity_pocket_id_admin_curl: method required}"
  local path="${2:?identity_pocket_id_admin_curl: path required}"
  local body="${3:-}"
  local api_key env_path code tmp_body tmp_hdr
  env_path="${ADMIN_ENV:?identity_pocket_id_admin_curl: ADMIN_ENV required}"
  api_key="$(identity_pocket_id_admin_api_key_from_env "${env_path}")" || return 1
  tmp_body="$(mktemp "${TMPDIR:-/tmp}/pocket-id-body.XXXXXX")"
  tmp_hdr="$(mktemp "${TMPDIR:-/tmp}/pocket-id-hdr.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_body}' '${tmp_hdr}'" RETURN

  if [[ -n "${body}" ]]; then
    code="$(
      quadlet_user env "HOME=${HOME_DIR}" bash -c \
        "cd \"\$HOME\" && podman run --rm --network service-network \
          docker.io/curlimages/curl:8.12.1 \
          curl -sS --connect-timeout 2 --max-time 12 --retry 0 \
            -D - -o $(printf '%q' "${tmp_body}") \
          -X $(printf '%q' "${method}") \
          -H $(printf '%q' "X-API-Key: ${api_key}") \
          -H 'Content-Type: application/json' \
          --data $(printf '%q' "${body}") \
          $(printf '%q' "http://identity:1411${path}")" \
        2>/dev/null | awk 'NR==1 { print $2; exit }'
    )"
  else
    code="$(
      quadlet_user env "HOME=${HOME_DIR}" bash -c \
        "cd \"\$HOME\" && podman run --rm --network service-network \
          docker.io/curlimages/curl:8.12.1 \
          curl -sS --connect-timeout 2 --max-time 12 --retry 0 \
            -D - -o $(printf '%q' "${tmp_body}") \
          -X $(printf '%q' "${method}") \
          -H $(printf '%q' "X-API-Key: ${api_key}") \
          $(printf '%q' "http://identity:1411${path}")" \
        2>/dev/null | awk 'NR==1 { print $2; exit }'
    )"
  fi

  if [[ -z "${code}" || "${code}" -ge 400 ]]; then
    echo "Identity Pocket ID admin ${method} ${path} failed (HTTP ${code:-unknown})" >&2
    if [[ -s "${tmp_body}" ]]; then
      cat "${tmp_body}" >&2
    fi
    return 1
  fi
  cat "${tmp_body}"
}

identity_pocket_id_discovery_issuer() {
  local issuer=""
  issuer="$(
    quadlet_user env "HOME=${HOME_DIR:?}" bash -c \
      "cd \"\$HOME\" && podman run --rm --network service-network \
        docker.io/curlimages/curl:8.12.1 \
        curl -fsS http://identity:1411/.well-known/openid-configuration" \
      2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])'
  )" || {
    echo "identity_pocket_id_discovery_issuer: OIDC discovery failed" >&2
    return 1
  }
  printf '%s\n' "${issuer}"
}

identity_pocket_id_api_list_all() {
  local page=1
  # Keep payload small: transient admin list slowness can lead to curl header
  # extraction failures and empty HTTP codes (HTTP unknown).
  local limit=20
  local combined=""
  while :; do
    local chunk total_pages
    chunk="$(identity_pocket_id_admin_curl GET "/api/apis?pagination[page]=${page}&pagination[limit]=${limit}")" \
      || return 1
    if [[ "${page}" -eq 1 ]]; then
      combined="${chunk}"
    else
      combined="$(python3 - "${combined}" "${chunk}" <<'PY'
import json, sys
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
a["data"].extend(b.get("data") or [])
a["pagination"] = b.get("pagination") or a.get("pagination") or {}
print(json.dumps(a))
PY
)"
    fi
    total_pages="$(printf '%s\n' "${combined}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pagination",{}).get("totalPages",1))')"
    if [[ "${page}" -ge "${total_pages}" ]]; then
      break
    fi
    page=$((page + 1))
  done
  printf '%s\n' "${combined}"
}

identity_pocket_id_api_find_by_resource() {
  local resource="${1:?identity_pocket_id_api_find_by_resource: resource required}"
  local list_json
  list_json="$(identity_pocket_id_api_list_all)" || return 1
  python3 - "${resource}" "${list_json}" <<'PY'
import json, sys
resource, payload_raw = sys.argv[1], sys.argv[2]
payload = json.loads(payload_raw)
for item in payload.get("data") or []:
    if item.get("resource") == resource:
        print(json.dumps(item))
        break
PY
}

identity_pocket_id_api_create() {
  local name="${1:?identity_pocket_id_api_create: name required}"
  local resource="${2:?identity_pocket_id_api_create: resource required}"
  local body
  body="$(python3 - "${name}" "${resource}" <<'PY'
import json, sys
print(json.dumps({"name": sys.argv[1], "resource": sys.argv[2]}))
PY
)"
  identity_pocket_id_admin_curl POST /api/apis "${body}"
}

identity_pocket_id_api_update_permissions() {
  local api_id="${1:?identity_pocket_id_api_update_permissions: api id required}"
  local permissions_json="${2:?identity_pocket_id_api_update_permissions: permissions json required}"
  local body
  body="$(python3 - "${permissions_json}" <<'PY'
import json, sys
permissions = json.loads(sys.argv[1])
print(json.dumps({"permissions": permissions}))
PY
)"
  identity_pocket_id_admin_curl PUT "/api/apis/${api_id}/permissions" "${body}"
}

identity_pocket_id_api_delete() {
  local api_id="${1:?identity_pocket_id_api_delete: api id required}"
  identity_pocket_id_admin_curl DELETE "/api/apis/${api_id}"
}

identity_pocket_id_api_access_put() {
  local client_id="${1:?identity_pocket_id_api_access_put: client id required}"
  local permission_ids_json="${2:?identity_pocket_id_api_access_put: permission ids required}"
  local body
  body="$(python3 - "${permission_ids_json}" <<'PY'
import json, sys
ids = json.loads(sys.argv[1])
print(json.dumps({
    "userDelegatedPermissionIds": ids,
    "clientPermissionIds": ids,
}))
PY
)"
  identity_pocket_id_admin_curl PUT "/api/api-access/${client_id}" "${body}"
}

identity_pocket_id_oidc_client_create() {
  local client_id="${1:?identity_pocket_id_oidc_client_create: client id required}"
  local name="${2:?identity_pocket_id_oidc_client_create: name required}"
  local is_public="${3:-false}"
  local callback_urls_json="${4:-[]}"
  local body
  body="$(python3 - "${client_id}" "${name}" "${is_public}" "${callback_urls_json}" <<'PY'
import json, sys
client_id, name, is_public, callback_urls_json = sys.argv[1:5]
callbacks = json.loads(callback_urls_json)
print(json.dumps({
    "id": client_id,
    "name": name,
    "isPublic": is_public.lower() == "true",
    "pkceEnabled": is_public.lower() == "true",
    "isGroupRestricted": False,
    "callbackURLs": callbacks,
    "logoutCallbackURLs": [],
}))
PY
)"
  identity_pocket_id_admin_curl POST /api/oidc/clients "${body}"
}

identity_pocket_id_oidc_client_get() {
  local client_id="${1:?identity_pocket_id_oidc_client_get: client id required}"
  identity_pocket_id_admin_curl GET "/api/oidc/clients/${client_id}"
}

identity_pocket_id_oidc_client_update() {
  local client_id="${1:?identity_pocket_id_oidc_client_update: client id required}"
  local name="${2:?identity_pocket_id_oidc_client_update: name required}"
  local is_public="${3:-true}"
  local callback_urls_json="${4:-[]}"
  local body
  body="$(python3 - "${name}" "${is_public}" "${callback_urls_json}" <<'PY'
import json, sys
name, is_public, callback_urls_json = sys.argv[1:4]
callbacks = json.loads(callback_urls_json)
print(json.dumps({
    "name": name,
    "isPublic": is_public.lower() == "true",
    "pkceEnabled": is_public.lower() == "true",
    "isGroupRestricted": False,
    "callbackURLs": callbacks,
    "logoutCallbackURLs": [],
}))
PY
)"
  identity_pocket_id_admin_curl PUT "/api/oidc/clients/${client_id}" "${body}"
}

identity_pocket_id_oidc_client_delete() {
  local client_id="${1:?identity_pocket_id_oidc_client_delete: client id required}"
  identity_pocket_id_admin_curl DELETE "/api/oidc/clients/${client_id}"
}

identity_pocket_id_oidc_client_secret_create() {
  local client_id="${1:?identity_pocket_id_oidc_client_secret_create: client id required}"
  identity_pocket_id_admin_curl POST "/api/oidc/clients/${client_id}/secret"
}

# Unauthenticated token endpoint (Service Network). Prints JSON token response.
identity_pocket_id_token_client_credentials() {
  local client_id="${1:?}"
  local client_secret="${2:?}"
  local resource="${3:?}"
  local scope="${4:?}"
  quadlet_user env "HOME=${HOME_DIR:?}" bash -c \
    "cd \"\$HOME\" && podman run --rm --network service-network \
      docker.io/curlimages/curl:8.12.1 \
      curl -sS -X POST http://identity:1411/api/oidc/token \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode client_id=$(printf '%q' "${client_id}") \
      --data-urlencode client_secret=$(printf '%q' "${client_secret}") \
      --data-urlencode grant_type=client_credentials \
      --data-urlencode resource=$(printf '%q' "${resource}") \
      --data-urlencode scope=$(printf '%q' "${scope}")"
}
