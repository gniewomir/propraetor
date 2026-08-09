#!/usr/bin/env bash
# Unit tests: Mirror Host half — upsert Environment trees; leave orphans (#156).
# Offline: temp Host Volume + staged Workload trees. No SSH / live Host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/ensure-mirror-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ensure-mirror.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
HV="${TMP}/host-volume"
STAGE="${TMP}/stage"
mkdir -p "${HV}" "${STAGE}/lib"
cp "${REPO_ROOT}/internals/host-scripts/lib/sync-tree-host.sh" "${STAGE}/lib/sync-tree-host.sh"

sed -e "s|/var/lib/host-volume|${HV}|g" "${HOST_SCRIPT}" >"${TMP}/mirror-run.sh"
chmod +x "${TMP}/mirror-run.sh"

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP}/bin/chown"
export PATH="${TMP}/bin:${PATH}"

USER_NAME="$(id -un)"

# Seed an orphan on the Host that must survive Mirror
mkdir -p "${HV}/internals/workloads/orphan-left/routes"
printf '{"intent":"run"}\n' >"${HV}/internals/workloads/orphan-left/manifest.json"
printf 'keep-orphan\n' >"${HV}/internals/workloads/orphan-left/routes/orphan.conf"
mkdir -p "${HV}/data/workloads/orphan-left"
printf 'durable\n' >"${HV}/data/workloads/orphan-left/state.bin"

# Stage Environment Workloads (new + update existing Host tree)
mkdir -p "${STAGE}/workloads/alpha/routes" \
  "${STAGE}/workloads/alpha/www/usage" \
  "${STAGE}/workloads/alpha/scripts" \
  "${STAGE}/workloads/beta/quadlets"
printf '{"intent":"run"}\n' >"${STAGE}/workloads/alpha/manifest.json"
printf 'route-a\n' >"${STAGE}/workloads/alpha/routes/a.conf"
printf 'home\n' >"${STAGE}/workloads/alpha/www/index.html"
printf 'nested\n' >"${STAGE}/workloads/alpha/www/usage/index.html"
printf '#!/bin/bash\necho ok\n' >"${STAGE}/workloads/alpha/scripts/alpha-job.sh"
printf 'not-even-json\n' >"${STAGE}/workloads/beta/manifest.json"
printf 'unit\n' >"${STAGE}/workloads/beta/quadlets/beta.container"

# Pre-existing Host tree for alpha that Mirror must update (upsert)
mkdir -p "${HV}/internals/workloads/alpha/routes"
printf '{"intent":"stop"}\n' >"${HV}/internals/workloads/alpha/manifest.json"
printf 'stale\n' >"${HV}/internals/workloads/alpha/routes/stale.conf"
printf 'old-a\n' >"${HV}/internals/workloads/alpha/routes/a.conf"

cp "${TMP}/mirror-run.sh" "${STAGE}/ensure-mirror-host.sh"
bash "${STAGE}/ensure-mirror-host.sh" "${USER_NAME}" \
  || fail "ensure-mirror-host failed"

# Adds new Workload
[[ -f "${HV}/internals/workloads/beta/manifest.json" ]] \
  || fail "Mirror did not add beta"
grep -Fxq 'unit' "${HV}/internals/workloads/beta/quadlets/beta.container" \
  || fail "beta quadlet not mirrored"
pass "Mirror adds Environment Workloads"

# Updates existing Workload tree (content + prune stale authored files)
grep -Fxq '{"intent":"run"}' "${HV}/internals/workloads/alpha/manifest.json" \
  || fail "alpha Manifest not upserted"
grep -Fxq 'route-a' "${HV}/internals/workloads/alpha/routes/a.conf" \
  || fail "alpha route not upserted"
grep -Fxq 'home' "${HV}/internals/workloads/alpha/www/index.html" \
  || fail "alpha www root not upserted"
grep -Fxq 'nested' "${HV}/internals/workloads/alpha/www/usage/index.html" \
  || fail "alpha nested www not upserted"
grep -Fq 'echo ok' "${HV}/internals/workloads/alpha/scripts/alpha-job.sh" \
  || fail "alpha scripts not upserted"
[[ ! -e "${HV}/internals/workloads/alpha/routes/stale.conf" ]] \
  || fail "stale authored file must be pruned within Mirrored tree"
pass "Mirror updates existing Host Workload trees"

# Leaves orphans alone (definition tree + durable data)
[[ -f "${HV}/internals/workloads/orphan-left/manifest.json" ]] \
  || fail "Mirror must leave orphan definition tree"
grep -Fxq 'keep-orphan' "${HV}/internals/workloads/orphan-left/routes/orphan.conf" \
  || fail "orphan routes must be untouched"
grep -Fxq 'durable' "${HV}/data/workloads/orphan-left/state.bin" \
  || fail "orphan durable data must be untouched"
pass "Mirror leaves orphan Host trees alone"

# Does not fail closed on invalid Manifest content
grep -Fxq 'not-even-json' "${HV}/internals/workloads/beta/manifest.json" \
  || fail "invalid Manifest content must still be copied"
pass "Mirror does not validate Manifest content"

echo "All ensure-mirror-host offline tests passed."
