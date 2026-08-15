#!/usr/bin/env bash
# Seam: Acceptance case isolation policy (ADR-0042 / #164) —
# no peer-pollution heal; no hand-rm of Host Volume data/; survive-Deploy
# ACME probes registered via acceptance_data_track.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- peer-pollution helper must be gone ---
if grep -n 'acceptance_drop_peer_location_root_routes' "${CASE_DIR}/lib.sh" >/dev/null 2>&1; then
  fail "lib.sh must not define acceptance_drop_peer_location_root_routes (peer-pollution heal banned)"
fi
pass "peer-heal helper absent from lib.sh"

peer_hits="$(grep -n 'acceptance_drop_peer_location_root_routes' "${CASE_DIR}"/[0-9]*.sh 2>/dev/null || true)"
[[ -z "${peer_hits}" ]] || fail "cases must not call peer-heal helper:
${peer_hits}"
pass "no case calls acceptance_drop_peer_location_root_routes"

# --- no hand-deletion of Host Volume data/ in cases ---
# Intent-expressed cleanup is via Deploy / purge-orphans / purge-trash, not rm of data/.
# Track multi-line rm commands (continuation with \).
data_rm_hits="$(
  awk '
    /^[[:space:]]*rm[[:space:]]/ { in_rm=1 }
    in_rm {
      if ($0 ~ /\/var\/lib\/host-volume\/data\//) print FILENAME ":" FNR ":" $0
      if ($0 !~ /\\[[:space:]]*$/) in_rm=0
    }
  ' "${CASE_DIR}"/[0-9]*.sh
)"
[[ -z "${data_rm_hits}" ]] || fail "cases must not hand-rm Host Volume data/ (use Intent Deploy/Purge/Reap or acceptance_data_track):
${data_rm_hits}"
pass "no case hand-rms Host Volume data/"

# --- survive-Deploy ACME probes must be tracked ---
require_data_track() {
  local case_file="$1"
  local rel_substr="$2"
  local path="${CASE_DIR}/${case_file}"
  [[ -f "${path}" ]] || fail "missing case ${case_file}"
  grep -q 'acceptance_data_track' "${path}" \
    || fail "${case_file} must call acceptance_data_track for survive-Deploy data/"
  grep -Fq "${rel_substr}" "${path}" \
    || fail "${case_file} must track path containing ${rel_substr}"
  pass "${case_file} registers survive-Deploy data/ via acceptance_data_track"
}

require_data_track "75-edge-acme-foundation.sh" \
  "components/edge/persist/acme-www/.well-known/acme-challenge/edge-acme-foundation-probe"
require_data_track "77-https-fixture-pem.sh" \
  "components/edge/persist/acme-www/.well-known/acme-challenge/"
require_data_track "83-domain-front-healthcheck.sh" \
  "components/edge/persist/acme-www/.well-known/acme-challenge/"

# --- diagnose-runnable cases must not write Environment SoT (ADR-0042 / #176) ---
# Fixture-class = references acceptance_wl_track / acceptance_sot_track.
# Non-fixture cases must not use acceptance_env_dir (Environment tree mutation seam).
env_write_hits=""
for case_path in "${CASE_DIR}"/[0-9]*.sh; do
  base="$(basename "${case_path}")"
  if grep -qE 'acceptance_wl_track|acceptance_sot_track' "${case_path}"; then
    continue
  fi
  hits="$(grep -n 'acceptance_env_dir' "${case_path}" || true)"
  if [[ -n "${hits}" ]]; then
    env_write_hits+="${base}:
${hits}
"
  fi
done
[[ -z "${env_write_hits}" ]] \
  || fail "diagnose-runnable cases must not call acceptance_env_dir (fixture-class or redesign):
${env_write_hits}"
pass "diagnose-runnable cases do not call acceptance_env_dir"

echo "All acceptance isolation policy checks passed."
