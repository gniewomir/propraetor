#!/usr/bin/env bash
# Offline contract: Identity Setup Pocket ID lock-safe recycle (#252 / ADR-0057).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETUP="${REPO_ROOT}/internals/host-scripts/lib/identity-setup-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${SETUP}" ]] || fail "missing ${SETUP}"

grep -Fq 'identity_stop_pod_gracefully' "${SETUP}" \
  || fail "standing ensure must stop Pocket ID gracefully before start"
grep -Fq 'identity_clear_stale_app_lock_if_idle' "${SETUP}" \
  || fail "standing ensure must clear stale Pocket ID application_lock when idle"
grep -Fq 'identity_start_pod' "${SETUP}" \
  || fail "standing ensure must start (not restart) the Identity pod"
grep -Fq 'restart identity-pod.service' "${SETUP}" \
  && fail "standing ensure must not restart identity-pod (Pocket ID lock race)"
grep -Fq 'identity_pod_already_ready' "${SETUP}" \
  || fail "standing ensure must skip recycle when admin env unchanged and Pocket ID ready"
grep -Fq 'identity-pocket-id.service failed before ready' "${SETUP}" \
  || fail "identity_wait_ready must fail closed on ActiveState=failed"
grep -Fq 'NetworkAlias=identity' \
  "${REPO_ROOT}/internals/components/identity/systemd/identity.pod" \
  || fail "identity.pod must NetworkAlias=identity"
if grep -Eq '^PublishPort=' \
  "${REPO_ROOT}/internals/components/identity/systemd/identity.pod"; then
  fail "identity.pod must not PublishPort"
fi

pre_body="$(awk '/^identity_setup_pre_workloads\(\)/,/^}/' "${SETUP}")"
printf '%s\n' "${pre_body}" | grep -Fq 'identity_standing_ensure' \
  || fail "pre-workloads must call identity_standing_ensure"
printf '%s\n' "${pre_body}" | grep -Fq 'identity_fulfill_declarations' \
  || fail "pre-workloads must call Declaration converge"
standing_line="$(printf '%s\n' "${pre_body}" | grep -n 'identity_standing_ensure' | head -n1 | cut -d: -f1)"
fulfill_line="$(printf '%s\n' "${pre_body}" | grep -n 'identity_fulfill_declarations' | head -n1 | cut -d: -f1)"
[[ "${standing_line}" -lt "${fulfill_line}" ]] \
  || fail "pre-workloads must standing ensure before Declaration converge"

post_body="$(awk '/^identity_setup_post_workloads\(\)/,/^}/' "${SETUP}")"
printf '%s\n' "${post_body}" | grep -Fq 'identity_standing_ensure' \
  || fail "post-workloads must call identity_standing_ensure"
printf '%s\n' "${post_body}" | grep -Fq 'identity_drop_absent_fulfillments' \
  || fail "post-workloads must drop Orphan-absent fulfillments"

pass "Identity standing ensure uses lock-safe Pocket ID recycle"

echo "All identity-setup-host offline tests passed."
