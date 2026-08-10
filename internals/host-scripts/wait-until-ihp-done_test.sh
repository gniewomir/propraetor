#!/usr/bin/env bash
# Unit tests: IHP Done Host Volume mount wait (ADR-0031), cutover reboot (ADR-0030),
# and Platform journal readiness (ADR-0050 / #196).
# Stubs cloud-init / sysctl / id / findmnt / runuser / journalctl / podman via PATH — no SSH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/internals/host-scripts/wait-until-ihp-done.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "${SCRIPT}" ]] || fail "missing ${SCRIPT}"

STUBS="$(mktemp -d "${TMPDIR:-/tmp}/ihp-done.XXXXXX")"
trap 'rm -rf "${STUBS}"' EXIT
STATE="${STUBS}/state"
FIXTURES="${STUBS}/fixtures"
mkdir -p "${STATE}" "${FIXTURES}"

write_platform_journal_fixtures() {
  cat >"${FIXTURES}/journald.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
SystemKeepFree=200M
RuntimeMaxUse=50M
EOF
  cat >"${FIXTURES}/containers.conf" <<'EOF'
[containers]
log_driver = "journald"
EOF
}

write_platform_journal_fixtures

cat >"${STUBS}/cloud-init" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" && "${2:-}" == "--wait" ]]; then
  echo "status: done"
  exit 0
fi
exit 0
EOF
chmod +x "${STUBS}/cloud-init"

cat >"${STUBS}/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--system" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-n" && "${2:-}" == "net.ipv4.ip_unprivileged_port_start" ]]; then
  echo 80
  exit 0
fi
exit 0
EOF
chmod +x "${STUBS}/sysctl"

cat >"${STUBS}/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  echo 1000
  exit 0
fi
exit 0
EOF
chmod +x "${STUBS}/id"

cat >"${STUBS}/findmnt" <<'EOF'
#!/usr/bin/env bash
# Succeed after FINDMT_SUCCEED_AFTER attempts (default: never).
set -euo pipefail
if [[ "${1:-}" != "--mountpoint" ]]; then
  exit 1
fi
count_file="${STUB_STATE}/findmnt_count"
n=0
if [[ -f "${count_file}" ]]; then
  n="$(cat "${count_file}")"
fi
n=$((n + 1))
printf '%s\n' "${n}" >"${count_file}"
need="${FINDMT_SUCCEED_AFTER:-999999}"
if [[ "${n}" -ge "${need}" ]]; then
  exit 0
fi
exit 1
EOF
chmod +x "${STUBS}/findmnt"

cat >"${STUBS}/runuser" <<'EOF'
#!/usr/bin/env bash
# runuser -u USER -- env KEY=VAL ... CMD...
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u)
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      shift
      ;;
  esac
done
exec "$@"
EOF
chmod +x "${STUBS}/runuser"

cat >"${STUBS}/journalctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${JOURNALCTL_FAIL:-}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "${STUBS}/journalctl"

cat >"${STUBS}/podman" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  # podman info --format '{{.Host.LogDriver}}'
  printf '%s\n' "${PODMAN_LOG_DRIVER:-journald}"
  exit 0
fi
exit 1
EOF
chmod +x "${STUBS}/podman"

run_gate() {
  rm -f "${STATE}/findmnt_count"
  env PATH="${STUBS}:/usr/bin:/bin" \
    STUB_STATE="${STATE}" \
    PLATFORM_USER=platform \
    HOST_VOLUME_MOUNT_WAIT_SECONDS="${HOST_VOLUME_MOUNT_WAIT_SECONDS:-30}" \
    HOST_VOLUME_MOUNT_POLL_SECONDS="${HOST_VOLUME_MOUNT_POLL_SECONDS:-1}" \
    FINDMT_SUCCEED_AFTER="${FINDMT_SUCCEED_AFTER:-}" \
    IHP_POWER_STATE_SEM_EPOCH="${IHP_POWER_STATE_SEM_EPOCH:-100}" \
    IHP_BOOT_EPOCH="${IHP_BOOT_EPOCH:-200}" \
    IHP_CUTOVER_REBOOT_WAIT_SECONDS="${IHP_CUTOVER_REBOOT_WAIT_SECONDS:-30}" \
    IHP_CUTOVER_REBOOT_POLL_SECONDS="${IHP_CUTOVER_REBOOT_POLL_SECONDS:-1}" \
    IHP_JOURNALD_DROPIN="${IHP_JOURNALD_DROPIN:-${FIXTURES}/journald.conf}" \
    IHP_CONTAINERS_CONF="${IHP_CONTAINERS_CONF:-${FIXTURES}/containers.conf}" \
    JOURNALCTL_FAIL="${JOURNALCTL_FAIL:-}" \
    PODMAN_LOG_DRIVER="${PODMAN_LOG_DRIVER:-journald}" \
    bash "${SCRIPT}" 2>"${STUBS}/err"
}

# --- retries until findmnt succeeds ---
export FINDMT_SUCCEED_AFTER=3
export HOST_VOLUME_MOUNT_WAIT_SECONDS=10
export HOST_VOLUME_MOUNT_POLL_SECONDS=1
run_gate || fail "gate should pass once findmnt succeeds on retry"
count="$(cat "${STATE}/findmnt_count")"
[[ "${count}" -ge 3 ]] || fail "expected at least 3 findmnt attempts, got ${count}"
pass "retries findmnt until Host Volume mount appears"

# --- timeout: message points at host-volume.service ---
export FINDMT_SUCCEED_AFTER=999999
export HOST_VOLUME_MOUNT_WAIT_SECONDS=2
export HOST_VOLUME_MOUNT_POLL_SECONDS=1
if run_gate; then
  fail "gate should fail when mount never appears"
fi
grep -q 'Host Volume mount /var/lib/host-volume missing' "${STUBS}/err" \
  || fail "expected mount-missing message, got: $(cat "${STUBS}/err")"
grep -q 'host-volume.service' "${STUBS}/err" \
  || fail "expected pointer to host-volume.service, got: $(cat "${STUBS}/err")"
pass "on timeout points at host-volume.service"

# --- ADR-0030: cutover reboot required (boot newer than power_state sem) ---
export FINDMT_SUCCEED_AFTER=1
export HOST_VOLUME_MOUNT_WAIT_SECONDS=10
export IHP_POWER_STATE_SEM_EPOCH=500
export IHP_BOOT_EPOCH=400
export IHP_CUTOVER_REBOOT_WAIT_SECONDS=2
export IHP_CUTOVER_REBOOT_POLL_SECONDS=1
if run_gate; then
  fail "gate should fail when boot is older than power_state sem"
fi
grep -q 'cutover reboot not observed' "${STUBS}/err" \
  || fail "expected cutover timeout message, got: $(cat "${STUBS}/err")"
pass "fails when cutover reboot has not landed"

export IHP_BOOT_EPOCH=600
run_gate || fail "gate should pass when boot is newer than power_state sem"
pass "passes once cutover reboot has landed"

# --- ADR-0050: Platform journal on-disk contract (fail closed) ---
export FINDMT_SUCCEED_AFTER=1
export HOST_VOLUME_MOUNT_WAIT_SECONDS=10
export IHP_POWER_STATE_SEM_EPOCH=100
export IHP_BOOT_EPOCH=200
export IHP_CUTOVER_REBOOT_WAIT_SECONDS=30
unset JOURNALCTL_FAIL PODMAN_LOG_DRIVER

# Missing journald drop-in
export IHP_JOURNALD_DROPIN="${FIXTURES}/missing-journald.conf"
if run_gate; then
  fail "gate should fail when Platform journal journald drop-in is missing"
fi
grep -q 'Platform journal' "${STUBS}/err" \
  || fail "expected Platform journal message, got: $(cat "${STUBS}/err")"
pass "fails when journald Platform journal drop-in is missing"
unset IHP_JOURNALD_DROPIN
write_platform_journal_fixtures

# Drop-in present but missing Storage=persistent
cat >"${FIXTURES}/journald.conf" <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
if run_gate; then
  fail "gate should fail when journald drop-in lacks Storage=persistent"
fi
grep -q 'Storage=persistent' "${STUBS}/err" \
  || fail "expected Storage=persistent message, got: $(cat "${STUBS}/err")"
pass "fails when journald drop-in lacks Storage=persistent"
write_platform_journal_fixtures

# Drop-in present but missing SystemMaxUse=200M
cat >"${FIXTURES}/journald.conf" <<'EOF'
[Journal]
Storage=persistent
SystemKeepFree=200M
RuntimeMaxUse=50M
EOF
if run_gate; then
  fail "gate should fail when journald drop-in lacks SystemMaxUse=200M"
fi
grep -q 'SystemMaxUse=200M' "${STUBS}/err" \
  || fail "expected SystemMaxUse=200M message, got: $(cat "${STUBS}/err")"
pass "fails when journald drop-in lacks SystemMaxUse=200M"
write_platform_journal_fixtures

# Missing containers.conf pin
export IHP_CONTAINERS_CONF="${FIXTURES}/missing-containers.conf"
if run_gate; then
  fail "gate should fail when Platform User containers.conf is missing"
fi
grep -q 'containers.conf' "${STUBS}/err" \
  || fail "expected containers.conf message, got: $(cat "${STUBS}/err")"
pass "fails when Platform User containers.conf is missing"
unset IHP_CONTAINERS_CONF
write_platform_journal_fixtures

# containers.conf present but log_driver not journald
cat >"${FIXTURES}/containers.conf" <<'EOF'
[containers]
log_driver = "k8s-file"
EOF
if run_gate; then
  fail "gate should fail when containers.conf does not pin journald"
fi
grep -Eq 'log_driver|journald' "${STUBS}/err" \
  || fail "expected journald pin message, got: $(cat "${STUBS}/err")"
pass "fails when containers.conf does not pin journald"
write_platform_journal_fixtures

# --- ADR-0050: cheap live probe (fail closed) ---
export JOURNALCTL_FAIL=1
if run_gate; then
  fail "gate should fail when Platform User journal is not openable"
fi
grep -Eq 'journal|Platform journal' "${STUBS}/err" \
  || fail "expected journal probe message, got: $(cat "${STUBS}/err")"
pass "fails when Platform User journal is not openable"
unset JOURNALCTL_FAIL

export PODMAN_LOG_DRIVER=k8s-file
if run_gate; then
  fail "gate should fail when Podman LogDriver is not journald"
fi
grep -Eq 'LogDriver|journald' "${STUBS}/err" \
  || fail "expected LogDriver probe message, got: $(cat "${STUBS}/err")"
pass "fails when Podman LogDriver is not journald"
unset PODMAN_LOG_DRIVER

run_gate || fail "gate should pass when on-disk contract and live probe succeed"
pass "passes with Platform journal on-disk contract and live probe"
