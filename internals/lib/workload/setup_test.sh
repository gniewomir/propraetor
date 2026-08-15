#!/usr/bin/env bash
# Unit tests: Workload Setup operator payload assembly (#233).
# Seam: workload_setup_stage_payload.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=setup.sh
source "${REPO_ROOT}/internals/lib/workload/setup.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-setup-stage.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

ENV_DIR="${TMP}/env"
WL_DIR="${ENV_DIR}/demo"
mkdir -p "${WL_DIR}/systemd"
cat >"${WL_DIR}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
printf '{}\n' >"${WL_DIR}/binding.json"
printf '{ "database": false, "cache": false, "environment": {} }\n' \
  >"${WL_DIR}/requires.json"
printf '{}\n' >"${WL_DIR}/provides.json"
printf '[Container]\nImage=localhost/demo\n' >"${WL_DIR}/systemd/demo.container"

STAGE="${TMP}/stage"
mkdir -p "${STAGE}"
REMOTE_ROOT="/tmp/platform-ensure-workload-test"

workload_setup_stage_payload "${STAGE}" "${REMOTE_ROOT}" "${WL_DIR}" \
  || fail "stage_payload must succeed for internal Workload"

[[ -f "${STAGE}/ensure-workload-host.sh" ]] || fail "missing Host entry script"
[[ -f "${STAGE}/workload-setup-host.sh" ]] || fail "missing Host apply module"
[[ -f "${STAGE}/workload-identity-host.sh" ]] || fail "missing identity module"
[[ -d "${STAGE}/demo" ]] || fail "Workload tree not staged"
[[ -f "${STAGE}/demo/manifest.json" ]] || fail "Manifest not staged"

for f in \
  sync-tree-host.sh \
  workload-materialize-host.sh \
  workload-project-host.sh \
  unit-consumers-host.sh \
  host-volume-paths-host.sh \
  source.sh \
  provides.sh \
  workload-units-host.sh \
  workload-quadlets-host.sh \
  workload-environment-host.sh \
  workload-manifest-host.sh \
  quadlet-user-session.sh \
  manifest.sh \
  binding.sh \
  requires.sh; do
  [[ -f "${STAGE}/${f}" ]] || fail "stage_payload missing ${f}"
done
pass "stage_payload ships projection + Setup inventory and Workload tree"

# Reserved basename refused at stage (same identity module as Host).
BAD="${ENV_DIR}/database"
mkdir -p "${BAD}/systemd"
cp "${WL_DIR}/manifest.json" "${BAD}/"
cp "${WL_DIR}/binding.json" "${BAD}/"
cp "${WL_DIR}/requires.json" "${BAD}/"
cp "${WL_DIR}/provides.json" "${BAD}/"
cp "${WL_DIR}/systemd/demo.container" "${BAD}/systemd/"
STAGE_BAD="${TMP}/stage-bad"
mkdir -p "${STAGE_BAD}"
if workload_setup_stage_payload "${STAGE_BAD}" "${REMOTE_ROOT}" "${BAD}" 2>/dev/null; then
  fail "stage_payload must refuse reserved basename database"
fi
pass "stage_payload refuses reserved basename"

# Operator entrypoint stages through the module (not an inline ship-list).
grep -Fq 'workload_setup_stage_payload' \
  "${REPO_ROOT}/internals/ensure-workload.sh" \
  || fail "ensure-workload.sh must call workload_setup_stage_payload"
if grep -E 'cp "\$\{(UNITS_LIB|PROJECT_LIB|MATERIALIZE_LIB)' \
  "${REPO_ROOT}/internals/ensure-workload.sh"; then
  fail "ensure-workload.sh must not own an inline Host lib ship-list"
fi
pass "operator Setup uses stage_payload module"

echo "All Workload Setup stage_payload checks passed."
