#!/usr/bin/env bash
# Unit seam: Component Setup slot callers after ADR-0043 / #181 / #182.
# Acceptance cases and helpers must pass an explicit slot; Deploy-alone HTTPS
# proof must not use the fulfillment helper as a Deploy heal.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${CASE_DIR}/../../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- ensure-components invokes always carry an explicit slot ---
bad_invokes="$(
  grep -nE 'ensure-components\.sh' "${CASE_DIR}"/[0-9]*.sh "${CASE_DIR}/lib.sh" 2>/dev/null \
    | grep -vE 'pre-workloads|post-workloads' \
    || true
)"
[[ -z "${bad_invokes}" ]] || fail "ensure-components callers must pass pre-workloads|post-workloads:
${bad_invokes}"
pass "Acceptance ensure-components callers use an explicit Setup slot"

# --- fulfillment helper is post-workloads composition ---
grep -Fq 'post-workloads' "${CASE_DIR}/lib.sh" \
  || fail "ensure_edge_route_fulfillment must invoke post-workloads"
grep -Eq 'ensure-components\.sh"[[:space:]]+post-workloads|ensure-components\.sh[[:space:]]+post-workloads' \
  "${CASE_DIR}/lib.sh" \
  || fail "ensure_edge_route_fulfillment must call ensure-components.sh post-workloads"
pass "ensure_edge_route_fulfillment composes Component Setup post-workloads"

# --- Deploy-alone product proof case exists and does not heal via the helper ---
PROOF="${CASE_DIR}/96-deploy-route-https.sh"
[[ -f "${PROOF}" ]] || fail "missing Deploy-alone Route HTTPS proof case ${PROOF}"
grep -Fq 'ensure.sh' "${PROOF}" \
  || fail "96-deploy-route-https must re-run Deploy ladder (ensure.sh)"
# Call sites only (ignore comments): bare helper name as a command token.
if grep -E '^[[:space:]]*ensure_edge_route_fulfillment([[:space:]]|$)' "${PROOF}" >/dev/null; then
  fail "96-deploy-route-https must not call ensure_edge_route_fulfillment"
fi
pass "Deploy-alone Route HTTPS proof case avoids fulfillment-helper heal"

# --- Intent-transition / Purge Edge refresh uses post-workloads (helper or direct) ---
refresh_cases=(
  "${CASE_DIR}/78-workload-intent-run-stop.sh"
  "${CASE_DIR}/79-workload-intent-trash-purge.sh"
  "${CASE_DIR}/81-workload-intent-trash.sh"
)
for case_path in "${refresh_cases[@]}"; do
  [[ -f "${case_path}" ]] || fail "missing Intent-transition case ${case_path}"
  if ! grep -Eq 'ensure_edge_route_fulfillment|ensure-components\.sh"[[:space:]]+post-workloads|ensure-components\.sh[[:space:]]+post-workloads' \
    "${case_path}"; then
    fail "$(basename "${case_path}") must refresh Edge via helper or ensure-components post-workloads"
  fi
done
pass "Intent-transition cases compose Edge refresh via post-workloads (helper or direct)"

# --- Acceptance does not author FQDN-as-filename Route SoT (ADR-0053 / #203) ---
fqdn_sot="$(
  grep -nE 'routes/\$\{(ROUTE_FQDN|HOST|FQDN)\}\.conf' "${CASE_DIR}"/[0-9]*.sh \
    || true
)"
[[ -z "${fqdn_sot}" ]] || fail "Acceptance must not author FQDN-as-filename Route SoT:
${fqdn_sot}"
pass "Acceptance Route SoT is Binding-attached Provides fragments"

# --- teaching examples used by Acceptance are ADR-0053 trees ---
example_dir="${REPO_ROOT}/environments/example"
for example_tree in "${example_dir}"/*; do
  [[ -d "${example_tree}" && -f "${example_tree}/manifest.json" ]] || continue
  for f in provides.json requires.json binding.json; do
    [[ -f "${example_tree}/${f}" ]] \
      || fail "example $(basename "${example_tree}") missing ${f}"
  done
  if grep -Eq '"environment"|"database"' "${example_tree}/manifest.json"; then
    fail "example $(basename "${example_tree}") Manifest still has retired environment/database"
  fi
done
pass "teaching examples used by Acceptance declare Provides/Requires/Binding, not Manifest env/db"

echo "All Component Setup slot caller checks passed."
