#!/usr/bin/env bash
# Unit tests: Orphan Reap Host half — removes absent basenames' trees (#156).
# Offline: stubs session / unit purge / Environment Configuration clear. No SSH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_SCRIPT="${REPO_ROOT}/internals/host-scripts/purge-orphans-host.sh"
ORPHAN_LIB="${REPO_ROOT}/internals/host-scripts/lib/orphan-reap-host.sh"
PATHS_LIB="${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/purge-orphans.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
HV="${TMP}/host-volume"
STAGE="${TMP}/stage"
mkdir -p "${STAGE}" "${HV}/workloads" "${HV}/workloads"

cp "${HOST_SCRIPT}" "${STAGE}/purge-orphans-host.sh"
cp "${ORPHAN_LIB}" "${STAGE}/orphan-reap-host.sh"
cp "${PATHS_LIB}" "${STAGE}/host-volume-paths-host.sh"
chmod +x "${STAGE}/purge-orphans-host.sh"
export HV_ROOT="${HV}"

# Stub Host libs: record purge/clear; fake session paths into TMP.
cat >"${STAGE}/workload-units-host.sh" <<EOF
workload_units_purge() {
  printf '%s\\n' "\$1" >>"${TMP}/purged-units"
}
EOF
cat >"${STAGE}/workload-environment-host.sh" <<EOF
environment_configuration_clear() {
  printf '%s\\n' "\$1" >>"${TMP}/cleared-env"
}
EOF
cat >"${STAGE}/quadlet-user-session.sh" <<EOF
quadlet_user_session_begin() {
  HOME_DIR="${TMP}/home"
  UNIT_DIR="\${HOME_DIR}/.config/containers/systemd"
  SYSTEMD_USER_DIR="\${HOME_DIR}/.config/systemd/user"
  mkdir -p "\${UNIT_DIR}" "\${SYSTEMD_USER_DIR}" "\${HOME_DIR}/.config"
}
quadlet_user_session_reload() {
  printf 'reload\\n' >>"${TMP}/reloads"
}
EOF

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TMP}/bin/chown"
export PATH="${TMP}/bin:${PATH}"

# Host: keep-me (in Environment) + orphan (absent) + durable Persist for both
mkdir -p \
  "${HV}/workloads/keep-me/quadlets" \
  "${HV}/workloads/orphan-gone/quadlets" \
  "${HV}/workloads/keep-me/persist" \
  "${HV}/workloads/orphan-gone/persist"
printf '{"intent":"run"}\n' >"${HV}/workloads/keep-me/manifest.json"
printf '{"intent":"run"}\n' >"${HV}/workloads/orphan-gone/manifest.json"
printf 'unit\n' >"${HV}/workloads/orphan-gone/quadlets/orphan.container"
printf 'keep-data\n' >"${HV}/workloads/keep-me/persist/state.bin"
printf 'orphan-data\n' >"${HV}/workloads/orphan-gone/persist/state.bin"

printf 'keep-me\n' >"${STAGE}/keep.txt"
: >"${TMP}/purged-units"
: >"${TMP}/cleared-env"
: >"${TMP}/reloads"

PLATFORM_USER="$(id -un)" bash "${STAGE}/purge-orphans-host.sh" \
  || fail "purge-orphans-host failed"

[[ -f "${HV}/workloads/keep-me/manifest.json" ]] \
  || fail "keep-me definition tree must survive"
grep -Fxq 'keep-data' "${HV}/workloads/keep-me/persist/state.bin" \
  || fail "keep-me durable data must survive"
[[ ! -e "${HV}/workloads/orphan-gone" ]] \
  || fail "orphan definition tree must be removed"
[[ ! -e "${HV}/workloads/orphan-gone" ]] \
  || fail "orphan durable data must be removed"
grep -Fxq 'orphan-gone' "${TMP}/purged-units" \
  || fail "orphan units must be purged"
grep -Fxq 'orphan-gone' "${TMP}/cleared-env" \
  || fail "orphan EnvironmentFiles must be cleared"
if grep -Fxq 'keep-me' "${TMP}/purged-units"; then
  fail "keep-me must not be unit-purged"
fi
grep -Fxq 'reload' "${TMP}/reloads" || fail "session reload must run"
pass "Orphan Reap removes absent basenames' trees, units, and EnvironmentFiles"

echo "All purge-orphans-host offline tests passed."
