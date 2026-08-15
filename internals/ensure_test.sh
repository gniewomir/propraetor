#!/usr/bin/env bash
# Unit tests: Deploy ladder orchestrator (ensure.sh) and root deploy.sh (#158 / ADR-0041).
# Seams: entrypoint presence; ladder composition order; Deploy does not Apply.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

INTERNALS="${REPO_ROOT}/internals"
ENSURE="${INTERNALS}/ensure.sh"
DEPLOY="${REPO_ROOT}/deploy.sh"

[[ -f "${ENSURE}" ]] || fail "missing ${ENSURE}"
[[ -f "${DEPLOY}" ]] || fail "missing ${DEPLOY}"
[[ -x "${ENSURE}" ]] || fail "ensure.sh not executable"
[[ -x "${DEPLOY}" ]] || fail "deploy.sh not executable"
pass "ensure.sh and deploy.sh entrypoints exist"

# Ladder order: Fabric → Mirror → Orphan Reap → Components pre-workloads →
# Workloads → Components post-workloads (no Purge — ADR-0054 / #217).
want_order=$'ensure-fabric.sh\nensure-mirror.sh\npurge-orphans.sh\nensure-components.sh pre-workloads\nensure-workloads.sh\nensure-components.sh post-workloads'
got_order="$(
  awk '
    /ensure-fabric\.sh/ { print "ensure-fabric.sh"; next }
    /ensure-mirror\.sh/ { print "ensure-mirror.sh"; next }
    /purge-orphans\.sh/ { print "purge-orphans.sh"; next }
    /ensure-components\.sh/ {
      if ($0 ~ /pre-workloads/) print "ensure-components.sh pre-workloads"
      else if ($0 ~ /post-workloads/) print "ensure-components.sh post-workloads"
      else print "ensure-components.sh"
      next
    }
    /ensure-workloads\.sh/ { print "ensure-workloads.sh"; next }
  ' "${ENSURE}"
)"
[[ "${got_order}" == "${want_order}" ]] || fail "ensure.sh ladder order want:
${want_order}
got:
${got_order}"
grep -Fq 'purge-trash' "${ENSURE}" && fail "ensure.sh must not invoke purge-trash" || true
pass "ensure.sh composes Deploy ladder without Purge (both Component Setup slots)"

grep -Eq 'apply\.sh|terraform[[:space:]]+apply' "${ENSURE}" \
  && fail "ensure.sh must not invoke Stack Apply" || true
pass "ensure.sh does not invoke Stack Apply"

# deploy.sh: wait IHP, invoke ensure.sh, never Apply.
grep -Fq 'ensure.sh' "${DEPLOY}" || fail "deploy.sh must invoke ensure.sh"
grep -Fq 'host_wait_until_ihp_done' "${DEPLOY}" || fail "deploy.sh must wait for IHP Done"
grep -Fq 'host_session_open' "${DEPLOY}" || fail "deploy.sh must open a Host session"
grep -Eq 'apply\.sh|terraform[[:space:]]+apply' "${DEPLOY}" \
  && fail "deploy.sh must not invoke Stack Apply" || true
pass "deploy.sh waits for IHP Done, runs ensure.sh, does not Apply"

# Acceptance suite baseline Deploy uses ensure.sh (not legacy fabric+components-only).
BASELINE="${REPO_ROOT}/internals/test/acceptance/baseline.sh"
RUNNER="${REPO_ROOT}/internals/test/acceptance/run.sh"
grep -Fq 'internals/ensure.sh' "${BASELINE}" || fail "Acceptance baseline must invoke ensure.sh"
grep -Fq 'acceptance_baseline_deployed' "${RUNNER}" \
  || fail "Acceptance runner must Deploy via acceptance_baseline_deployed before each case"
grep -Fq 'ensure-fabric.sh' "${RUNNER}" && fail "Acceptance runner must not call ensure-fabric directly" || true
grep -Fq 'ensure-components.sh' "${RUNNER}" && fail "Acceptance runner must not call ensure-components directly" || true
pass "Acceptance baseline Deploy uses ensure.sh before each case"

echo "All ensure/deploy ladder checks passed."
