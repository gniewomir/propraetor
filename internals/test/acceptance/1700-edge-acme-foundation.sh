#!/usr/bin/env bash
# Acceptance Test: Edge ACME foundation after ensure-components (no live CA)
# Covers: :443 published, HTTP-01 webroot on :80, want-list presence, ACME oneshot + user timer, empty Edge 404.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

USER_NAME="${PLATFORM_USER:-platform}"
DATA_ROOT=/host-volume/components/edge/persist
ACME_WWW="${DATA_ROOT}/acme-www"
WANT_LIST="${DATA_ROOT}/acme/want-list"
TOKEN="edge-acme-foundation-probe"
TOKEN_PATH="${ACME_WWW}/.well-known/acme-challenge/${TOKEN}"
acceptance_data_track "components/edge/persist/acme-www/.well-known/acme-challenge/edge-acme-foundation-probe"
trap 'acceptance_wl_cleanup' EXIT

# Host :443 is published by the Edge (listener present — TLS shells come later).
# Retry: ensure-components may briefly bounce the Edge Pod.
listening=0
for _ in $(seq 1 30); do
  if host_ssh "ss -ltn | grep -qE ':443[[:space:]]'"; then
    listening=1
    break
  fi
  sleep 1
done
if [[ "${listening}" -ne 1 ]]; then
  fail "Host :443 is not listening (Edge should PublishPort 443)"
fi
pass "Edge publishes Host :443"

# Empty Edge :80 still 404 on /
code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 "http://${IP}/" || true)"
if [[ "${code}" != "404" ]]; then
  fail "empty Edge on Host :80: expected HTTP 404, got '${code}'"
fi
pass "empty Edge still returns HTTP 404 on /"

# :80 serves the ACME HTTP-01 webroot path
host_ssh bash -s <<REMOTE
set -euo pipefail
mkdir -p "$(dirname "${TOKEN_PATH}")"
printf '%s\n' '${TOKEN}' >"${TOKEN_PATH}"
chown -R ${USER_NAME}:${USER_NAME} "${ACME_WWW}"
REMOTE

body="$(curl -sS --connect-timeout 10 --max-time 15 "http://${IP}/.well-known/acme-challenge/${TOKEN}" || true)"
if [[ "${body}" != "${TOKEN}" ]]; then
  fail "ACME webroot on :80: expected body '${TOKEN}', got '${body}'"
fi
pass "Edge serves ACME HTTP-01 webroot on :80"

# ensure-components installs the Domain-derived want-list. 1800-acme-oneshot-trigger owns its exact contents.
host_ssh "test -f '${WANT_LIST}'" \
  || fail "ACME want-list file missing"
pass "ACME want-list is present"

# Oneshot + timer installed under Platform User; exercise the unit without CA contact.
host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM="\$(id -u ${USER_NAME})"
export XDG_RUNTIME_DIR="/run/user/\${UID_NUM}"
systemctl start "user@\${UID_NUM}.service"
trap 'runuser -u ${USER_NAME} -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" systemctl --user unset-environment EDGE_ACME_ISSUE' EXIT
runuser -u ${USER_NAME} -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" \
  systemctl --user set-environment EDGE_ACME_ISSUE=0
runuser -u ${USER_NAME} -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" \
  systemctl --user --quiet is-active edge-acme.timer
runuser -u ${USER_NAME} -- env XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR" \
  systemctl --user restart edge-acme.service
REMOTE
pass "Edge ACME timer active; oneshot succeeds"
