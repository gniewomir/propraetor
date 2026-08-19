#!/usr/bin/env bash
# Unit tests: Edge Identity issuer FQDN + route-collision guard (ADR-0057 / #252).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=edge-identity-issuer-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/edge-identity-issuer-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/edge-identity-issuer.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

HANDOFF="${TMP}/handoff"
mkdir -p "${HANDOFF}"
export HV_ROOT="${TMP}/host-volume"
mkdir -p "${HV_ROOT}/components/handoff"
cp "${HANDOFF}/identity.json" "${HV_ROOT}/components/handoff/identity.json" 2>/dev/null || true

# component_handoff_identity_config reads from host volume handoff root
printf '%s\n' '{"fqdn":"auth.example.test"}' >"${HV_ROOT}/components/handoff/identity.json"

got="$(edge_identity_issuer_fqdn_from_handoff)" \
  || fail "issuer FQDN from handoff failed"
[[ "${got}" == "auth.example.test" ]] \
  || fail "issuer FQDN wrong: ${got}"
pass "reads issuer FQDN from Identity handoff"

# --- route collision: Intent-run Binding on issuer FQDN fails closed ---
WL_ROOT="${TMP}/workloads"
mkdir -p "${WL_ROOT}/offender/routes"
printf '%s\n' '{"intent":"run"}' >"${WL_ROOT}/offender/manifest.json"
printf '%s\n' '{ "database": false, "cache": false }' >"${WL_ROOT}/offender/requires.json"
printf '%s\n' 'location / { return 200 "x"; }' >"${WL_ROOT}/offender/routes/fragment.conf"
printf '%s\n' '{"routes":{"routes/fragment.conf":"test"}}' >"${WL_ROOT}/offender/provides.json"
printf '%s\n' '{"domains":{"auth.example.test":["routes/fragment.conf"]}}' >"${WL_ROOT}/offender/binding.json"

if edge_routes_reject_issuer_collision "${WL_ROOT}" "auth.example.test" 2>/dev/null; then
  fail "Binding Routes on issuer FQDN must fail closed"
fi
pass "route collision fails closed for Intent-run Binding on issuer FQDN"

# --- other FQDN is allowed ---
rm -rf "${WL_ROOT}/offender"
mkdir -p "${WL_ROOT}/ok/routes"
printf '%s\n' '{"intent":"run"}' >"${WL_ROOT}/ok/manifest.json"
printf '%s\n' '{ "database": false, "cache": false }' >"${WL_ROOT}/ok/requires.json"
printf '%s\n' 'location / { return 200 "x"; }' >"${WL_ROOT}/ok/routes/fragment.conf"
printf '%s\n' '{"routes":{"routes/fragment.conf":"test"}}' >"${WL_ROOT}/ok/provides.json"
printf '%s\n' '{"domains":{"www.example.test":["routes/fragment.conf"]}}' >"${WL_ROOT}/ok/binding.json"
edge_routes_reject_issuer_collision "${WL_ROOT}" "auth.example.test" \
  || fail "non-issuer FQDN Binding must pass collision check"
pass "non-issuer FQDN Binding passes collision check"

# --- Intent stop on issuer FQDN is ignored ---
mkdir -p "${WL_ROOT}/stopped/routes"
printf '%s\n' '{"intent":"stop"}' >"${WL_ROOT}/stopped/manifest.json"
printf '%s\n' '{"domains":{"auth.example.test":["routes/fragment.conf"]}}' >"${WL_ROOT}/stopped/binding.json"
edge_routes_reject_issuer_collision "${WL_ROOT}" "auth.example.test" \
  || fail "Intent stop Binding on issuer FQDN must not collide"
pass "Intent stop Binding on issuer FQDN does not collide"

echo "All Edge Identity issuer helper checks passed."
