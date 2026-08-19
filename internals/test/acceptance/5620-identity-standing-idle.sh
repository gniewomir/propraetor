#!/usr/bin/env bash
# Acceptance Test: Identity Component standing idle with zero claimants (ADR-0057 / #252).
# After Deploy: Pocket ID up on Service Network dial name identity; Host Volume interior
# present; no Host-published Identity port; issuer Domain front proxies through Edge.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_ip
acceptance_host_session
[[ -n "${REPO_ROOT:-}" ]] || fail "fixture missing REPO_ROOT (run via ./test.sh acceptance)"

USER_NAME="${PLATFORM_USER:-platform}"
DATA_ROOT=/host-volume/components/identity/persist
INTERNALS=/host-volume/components/identity
ENV_SLUG="${PLATFORM_ENV:-test}"
ENV_DIR="${REPO_ROOT}/environments/${ENV_SLUG}"
# shellcheck source=../../lib/identity/identity-config.sh
source "${REPO_ROOT}/internals/lib/identity/identity-config.sh"
ISSUER_FQDN="$(identity_config_issuer_fqdn_for "${ENV_SLUG}")" \
  || fail "committed identity.json must validate for Environment ${ENV_SLUG}"

# Standing idle: no Environment Workload Declares Requires identity: true.
claimants="$(
  find "${ENV_DIR}" -mindepth 2 -maxdepth 2 -name requires.json -print0 2>/dev/null \
    | xargs -0 grep -l '"identity"[[:space:]]*:[[:space:]]*true' 2>/dev/null \
    || true
)"
[[ -z "${claimants}" ]] \
  || fail "expected zero Requires identity:true claimants, found: ${claimants}"
pass "no Requires identity:true claimants in Environment ${ENV_SLUG}"

must_be_dir() {
  local path="$1"
  host_ssh "test -d '${path}'" || fail "expected directory missing: ${path}"
}

must_be_file() {
  local path="$1"
  host_ssh "test -f '${path}'" || fail "expected file missing: ${path}"
}

must_be_dir "${INTERNALS}"
must_be_file "${INTERNALS}/pre-workloads.sh"
must_be_file "${INTERNALS}/post-workloads.sh"
must_be_file "${INTERNALS}/systemd/identity.pod"
must_be_file "${INTERNALS}/systemd/identity-pocket-id.container"
must_be_dir "${DATA_ROOT}/admin"
must_be_dir "${DATA_ROOT}/data"
must_be_file "${DATA_ROOT}/admin/environment"
pass "Identity Component source and Host Volume interior present"

# Authored pod must not publish Host ports (Service Network only).
if host_ssh "grep -E '^PublishPort=' '${INTERNALS}/systemd/identity.pod'"; then
  fail "identity.pod must not PublishPort (no Host-published Identity)"
fi
pass "identity.pod has no PublishPort"

pod_active="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u ${USER_NAME} -- env XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  systemctl --user show -p ActiveState --value identity-pod.service 2>/dev/null || echo ""
REMOTE
)"
[[ "${pod_active}" == "active" ]] || fail "identity-pod.service expected active, got '${pod_active}'"
pass "identity-pod.service is active (idle standing Component)"

# Service Network dial name identity answers OIDC discovery.
reach_ok="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
HOME_DIR=\$(getent passwd ${USER_NAME} | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
ok=no
for _ in \$(seq 1 30); do
  if runuser -u ${USER_NAME} -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
    bash -c 'cd "\$HOME" && podman run --rm --network service-network \
      docker.io/curlimages/curl:8.12.1 \
      curl -fsS http://identity:1411/.well-known/openid-configuration' \
    2>/dev/null | grep -Fq '"issuer"'; then
    ok=yes
    break
  fi
  sleep 1
done
printf '%s\n' "\${ok}"
REMOTE
)"
[[ "${reach_ok}" == "yes" ]] \
  || fail "Service Network dial name identity should answer OIDC discovery"
pass "Service Network dial name identity answers OIDC discovery"

# Issuer Domain front on Edge proxies to Identity (not Workload Routes).
issuer_front="$(host_ssh "cat '/host-volume/components/edge/persist/domains/${ISSUER_FQDN}.conf'")"
printf '%s\n' "${issuer_front}" | grep -Fq 'proxy_pass http://identity:1411;' \
  || fail "issuer Domain front must proxy to Identity dial name"
if printf '%s\n' "${issuer_front}" | grep -Fq "edge-routes/*--${ISSUER_FQDN}.conf"; then
  fail "issuer Domain front must not include Workload Route fragments"
fi
pass "issuer Domain front on Edge proxies to Identity"

# No Host port bindings on the Pocket ID container.
bindings="$(host_ssh bash -s <<REMOTE
set -euo pipefail
UID_NUM=\$(id -u ${USER_NAME})
HOME_DIR=\$(getent passwd ${USER_NAME} | cut -d: -f6)
export XDG_RUNTIME_DIR=/run/user/\${UID_NUM}
runuser -u ${USER_NAME} -- env HOME=\${HOME_DIR} XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${UID_NUM}/bus \
  bash -c 'cd "\$HOME" && podman inspect --format "{{json .HostConfig.PortBindings}}" identity-pocket-id' 2>/dev/null || echo null
REMOTE
)"
if [[ -n "${bindings}" && "${bindings}" != "null" && "${bindings}" != "{}" && "${bindings}" != "map[]" ]]; then
  fail "identity-pocket-id must not publish Host ports; PortBindings='${bindings}'"
fi
pass "identity-pocket-id has no Host PortBindings"
