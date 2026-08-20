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
#   identity_pocket_id_signup_setup_status
#   identity_pocket_id_user_create USERNAME EMAIL
#   identity_pocket_id_one_time_access_token_create USER_ID [TTL]
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
#
# Body must travel on the curl container's stdout: a host-side -o path is not
# mounted into `podman run`, so writing there silently yields an empty body
# while still returning HTTP 200. Shape: "<body>\n<http_code>" via -w.
identity_pocket_id_admin_curl() {
  local method="${1:?identity_pocket_id_admin_curl: method required}"
  local path="${2:?identity_pocket_id_admin_curl: path required}"
  local body="${3:-}"
  local api_key env_path code combined response_body
  env_path="${ADMIN_ENV:?identity_pocket_id_admin_curl: ADMIN_ENV required}"
  api_key="$(identity_pocket_id_admin_api_key_from_env "${env_path}")" || return 1

  if [[ -n "${body}" ]]; then
    combined="$(
      quadlet_user env "HOME=${HOME_DIR}" bash -c \
        "cd \"\$HOME\" && podman run --rm --network service-network \
          docker.io/curlimages/curl:8.12.1 \
          curl -sS --connect-timeout 5 --max-time 25 --retry 0 \
            -w '\n%{http_code}' \
          -X $(printf '%q' "${method}") \
          -H $(printf '%q' "X-API-Key: ${api_key}") \
          -H 'Content-Type: application/json' \
          --data $(printf '%q' "${body}") \
          $(printf '%q' "http://identity:1411${path}") \
        2>/dev/null"
    )"
  else
    combined="$(
      quadlet_user env "HOME=${HOME_DIR}" bash -c \
        "cd \"\$HOME\" && podman run --rm --network service-network \
          docker.io/curlimages/curl:8.12.1 \
          curl -sS --connect-timeout 5 --max-time 25 --retry 0 \
            -w '\n%{http_code}' \
          -X $(printf '%q' "${method}") \
          -H $(printf '%q' "X-API-Key: ${api_key}") \
          $(printf '%q' "http://identity:1411${path}") \
        2>/dev/null"
    )"
  fi

  if [[ -z "${combined}" ]]; then
    echo "Identity Pocket ID admin ${method} ${path} failed (HTTP unknown)" >&2
    return 1
  fi
  code="$(printf '%s\n' "${combined}" | tail -n1)"
  response_body="$(printf '%s\n' "${combined}" | sed '$d')"

  if [[ -z "${code}" || "${code}" -ge 400 ]]; then
    echo "Identity Pocket ID admin ${method} ${path} failed (HTTP ${code:-unknown})" >&2
    if [[ -n "${response_body}" ]]; then
      # Print failure body to stdout so callers that capture output (e.g.
      # create-then-conflict) can parse IDs without relying on a follow-up GET.
      printf '%s\n' "${response_body}"
    fi
    return 1
  fi
  printf '%s\n' "${response_body}"
}

# Probe GET /api/signup/setup (Pocket ID v2.13).
# Prints "available" (HTTP 204 — zero real users) or "completed" (HTTP 404).
# Fail closed on any other status / transport error.
identity_pocket_id_signup_setup_status() {
  local errf body ec
  errf="$(mktemp "${TMPDIR:-/tmp}/identity-signup-setup.XXXXXX")"
  # admin_curl: 204 → success (empty body); 404 → stderr "HTTP 404" + body on stdout.
  # Capture exit status without tripping set -e on the failing probe.
  ec=0
  body="$(identity_pocket_id_admin_curl GET /api/signup/setup 2>"${errf}")" || ec=$?
  if [[ "${ec}" -eq 0 ]]; then
    rm -f "${errf}"
    printf 'available\n'
    return 0
  fi
  if grep -q 'HTTP 404' "${errf}" 2>/dev/null \
    || printf '%s' "${body}" | grep -Eq 'setup_not_available'; then
    rm -f "${errf}"
    printf 'completed\n'
    return 0
  fi
  if [[ -s "${errf}" ]]; then
    cat "${errf}" >&2 || true
  fi
  rm -f "${errf}"
  echo "identity_pocket_id_signup_setup_status: unexpected failure probing /api/signup/setup" >&2
  return 1
}

# Create a Pocket ID user (admin). Prints UserDto JSON.
identity_pocket_id_user_create() {
  local username="${1:?identity_pocket_id_user_create: username required}"
  local email="${2:?identity_pocket_id_user_create: email required}"
  local body
  body="$(python3 - "${username}" "${email}" <<'PY'
import json, sys
username, email = sys.argv[1], sys.argv[2]
print(json.dumps({
    "username": username,
    "email": email,
    "emailVerified": True,
    "firstName": "Admin",
    "lastName": "",
    "displayName": "Admin",
    "isAdmin": True,
}))
PY
)"
  identity_pocket_id_admin_curl POST /api/users "${body}"
}

# Mint a one-time access token for a user. Prints the raw token string.
identity_pocket_id_one_time_access_token_create() {
  local user_id="${1:?identity_pocket_id_one_time_access_token_create: user id required}"
  local ttl="${2:-24h}"
  local body response token
  body="$(python3 - "${ttl}" <<'PY'
import json, sys
print(json.dumps({"ttl": sys.argv[1]}))
PY
)"
  response="$(identity_pocket_id_admin_curl POST \
    "/api/users/${user_id}/one-time-access-token" "${body}")" || return 1
  token="$(printf '%s\n' "${response}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["token"])')" || {
    echo "identity_pocket_id_one_time_access_token_create: token missing in response" >&2
    return 1
  }
  [[ -n "${token}" ]] || {
    echo "identity_pocket_id_one_time_access_token_create: empty token" >&2
    return 1
  }
  printf '%s\n' "${token}"
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
  # Pocket ID admin list endpoint has shown transient flakiness/timeouts when
  # passing pagination[page]. The acceptance suite probe uses a single request
  # without pagination[page], so match that shape here.
  identity_pocket_id_admin_curl GET "/api/apis"
}

identity_pocket_id_api_find_by_resource() {
  local resource="${1:?identity_pocket_id_api_find_by_resource: resource required}"
  local list_json
  list_json="$(identity_pocket_id_api_list_all)" || return 1
  [[ -n "${list_json}" ]] || return 1
  python3 - "${resource}" "${list_json}" <<'PY'
import json, sys
resource, payload_raw = sys.argv[1], sys.argv[2]
try:
    payload = json.loads(payload_raw)
except json.JSONDecodeError:
    sys.exit(1)
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
