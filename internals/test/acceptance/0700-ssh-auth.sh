#!/usr/bin/env bash
# Acceptance Test: SSH pubkey to root works; password auth not offered
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session

if host_ssh "true" 2>/dev/null; then
  pass "SSH public-key auth to root@${IP}"
else
  fail "SSH public-key auth to root@${IP} failed (set PROPRAETOR_PRIVATE_KEY_PATH to the matching private key)"
fi

# Password auth must not be offered (BatchMode exit alone is a false positive).
# Same Environment-scoped known_hosts as Host-session (not ~/.ssh/known_hosts).
KH="$(propraetor_ssh_known_hosts_path)" || fail "Environment known_hosts path unavailable"
set +e
SSH_PW_OUT="$(ssh -v -o "Port=${PLATFORM_SSH_PORT}" -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
  -o "UserKnownHostsFile=${KH}" -o GlobalKnownHostsFile=/dev/null \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=0 \
  "root@${IP}" "true" 2>&1)"
SSH_PW_RC=$?
set -e

echo "${SSH_PW_OUT}" | grep -q "Authentications that can continue" \
  || fail "SSH password check did not reach auth negotiation"

if echo "${SSH_PW_OUT}" | grep -E "Authentications that can continue:.*(password|keyboard-interactive)" >/dev/null; then
  fail "SSH password auth unexpectedly offered by server"
fi

[[ ${SSH_PW_RC} -ne 0 ]] || fail "SSH password auth unexpectedly succeeded"
pass "SSH password auth not offered"
