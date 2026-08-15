#!/usr/bin/env bash
# Wait until Initial Host Provisioning Done (IHP Done) for Component Setup.
# Runs on the Host only (as root). Success means Initial Host Provisioning
# outcomes required for Components hold: IHP finished, ADR-0030 SSH port
# cutover reboot completed, port floor 80, Platform User present, Host Volume
# mounted at /host-volume, and Platform journal readiness (ADR-0050).
# Usage: PLATFORM_USER=platform ./wait-until-ihp-done.sh
# Optional: PLATFORM_USER (default platform)
# Test overrides: IHP_POWER_STATE_SEM, IHP_POWER_STATE_SEM_EPOCH, IHP_BOOT_EPOCH,
#   IHP_CUTOVER_REBOOT_WAIT_SECONDS, IHP_CUTOVER_REBOOT_POLL_SECONDS,
#   HOST_VOLUME_MOUNT_WAIT_SECONDS, HOST_VOLUME_MOUNT_POLL_SECONDS,
#   IHP_JOURNALD_DROPIN, IHP_CONTAINERS_CONF
set -euo pipefail

USER_NAME="${PLATFORM_USER:-platform}"
# File execution: resolve sibling lib. Operator bash -s delivery (host_wait_until_ihp_done)
# prepends the lib because BASH_SOURCE is unbound under stdin + set -u.
_ihp_src="${BASH_SOURCE[0]:-}"
if [[ -n "${_ihp_src}" && -f "${_ihp_src}" ]]; then
  _ihp_here="$(cd "$(dirname "${_ihp_src}")" && pwd)"
  # shellcheck source=lib/host-volume-paths-host.sh
  source "${_ihp_here}/lib/host-volume-paths-host.sh"
elif ! declare -F host_volume_mount_root >/dev/null 2>&1; then
  echo "host_volume_mount_root unavailable (run as a file or via host_wait_until_ihp_done)" >&2
  exit 1
fi
JOURNALD_DROPIN="${IHP_JOURNALD_DROPIN:-/etc/systemd/journald.conf.d/99-platform-journal.conf}"
CONTAINERS_CONF="${IHP_CONTAINERS_CONF:-/home/${USER_NAME}/.config/containers/containers.conf}"
HV_MOUNT="$(host_volume_mount_root)"

echo "Waiting for Initial Host Provisioning..." >&2
# cloud-init ≥23.4: 0 = clean success; non-zero includes 2 = finished with
# recoverable errors (still "status: done") and 1 = crashed / not finished.
# Require clean success for now so degradations surface immediately; may relax
# later. Delivery detail — not part of this module's public interface. Leave
# stdout alone so --wait progress dots (and the final status line) show the
# wait is live.
set +e
cloud-init status --wait
rc=$?
set -e
if [[ ${rc} -ne 0 ]]; then
  echo "Initial Host Provisioning wait failed (exit ${rc})" >&2
  cloud-init status --long >&2 || true
  exit 1
fi

# ADR-0030: power_state schedules reboot as cloud-init exits. status --wait
# returns on that first boot before shutdown; SSH drops moments later. IHP Done
# requires a boot newer than the power_state sem (cutover landed). On the first
# boot this loop runs until reboot kills the session — operator retries SSH.
SEM="${IHP_POWER_STATE_SEM:-/var/lib/cloud/instance/sem/config_power_state_change}"
CUTOVER_WAIT_SECONDS="${IHP_CUTOVER_REBOOT_WAIT_SECONDS:-300}"
CUTOVER_POLL_SECONDS="${IHP_CUTOVER_REBOOT_POLL_SECONDS:-2}"
echo "Waiting for IHP SSH port cutover reboot..." >&2
cutover_deadline=$((SECONDS + CUTOVER_WAIT_SECONDS))
while true; do
  sem_epoch="${IHP_POWER_STATE_SEM_EPOCH:-}"
  if [[ -z "${sem_epoch}" && -f "${SEM}" ]]; then
    sem_epoch="$(stat -c %Y "${SEM}")"
  fi
  if [[ -n "${IHP_BOOT_EPOCH:-}" ]]; then
    btime="${IHP_BOOT_EPOCH}"
  else
    btime="$(awk '/^btime / { print $2; exit }' /proc/stat)"
  fi
  if [[ -n "${sem_epoch}" && -n "${btime}" && "${btime}" -gt "${sem_epoch}" ]]; then
    break
  fi
  if ((SECONDS >= cutover_deadline)); then
    echo "IHP SSH port cutover reboot not observed within ${CUTOVER_WAIT_SECONDS}s (ADR-0030)" >&2
    exit 1
  fi
  sleep "${CUTOVER_POLL_SECONDS}"
done

sysctl --system >/dev/null 2>&1 || true
floor="$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || true)"
if [[ "${floor}" != "80" ]]; then
  echo "net.ipv4.ip_unprivileged_port_start is '${floor}', expected 80 (ADR-0006)" >&2
  exit 1
fi

id "${USER_NAME}" >/dev/null

# Host Volume mount wait budget must stay aligned with host-volume.service
# start-limit window (ADR-0031). Override only in tests.
WAIT_SECONDS="${HOST_VOLUME_MOUNT_WAIT_SECONDS:-300}"
POLL_SECONDS="${HOST_VOLUME_MOUNT_POLL_SECONDS:-2}"
deadline=$((SECONDS + WAIT_SECONDS))
# findmnt MOUNTPOINT (not -T): -T follows the path and can match / if unmounted.
while ! findmnt --mountpoint "${HV_MOUNT}" >/dev/null 2>&1; do
  if ((SECONDS >= deadline)); then
    echo "Host Volume mount ${HV_MOUNT} missing after ${WAIT_SECONDS}s (see host-volume.service)" >&2
    exit 1
  fi
  sleep "${POLL_SECONDS}"
done

# ADR-0050: Platform journal Substrate — on-disk contract (fail closed).
if [[ ! -f "${JOURNALD_DROPIN}" ]]; then
  echo "Platform journal: journald drop-in missing at ${JOURNALD_DROPIN} (ADR-0050)" >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*Storage=persistent([[:space:]]|$)' "${JOURNALD_DROPIN}"; then
  echo "Platform journal: journald drop-in missing Storage=persistent (ADR-0050)" >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*SystemMaxUse=200M([[:space:]]|$)' "${JOURNALD_DROPIN}"; then
  echo "Platform journal: journald drop-in missing SystemMaxUse=200M (ADR-0050)" >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*SystemKeepFree=' "${JOURNALD_DROPIN}"; then
  echo "Platform journal: journald drop-in missing SystemKeepFree= (ADR-0050)" >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*RuntimeMaxUse=' "${JOURNALD_DROPIN}"; then
  echo "Platform journal: journald drop-in missing RuntimeMaxUse= (ADR-0050)" >&2
  exit 1
fi
if [[ ! -f "${CONTAINERS_CONF}" ]]; then
  echo "Platform journal: Platform User containers.conf missing at ${CONTAINERS_CONF} (ADR-0050)" >&2
  exit 1
fi
if ! grep -Eq '^[[:space:]]*log_driver[[:space:]]*=[[:space:]]*"journald"([[:space:]]|$)' "${CONTAINERS_CONF}"; then
  echo "Platform journal: containers.conf missing log_driver = \"journald\" pin (ADR-0050)" >&2
  exit 1
fi

# ADR-0050: cheap live probe — Platform User can open the user journal and Podman
# reports LogDriver=journald (not a full log round-trip). Both halves required so
# "config present but journal unusable" and "pin ignored" both fail closed.
#
# Root SSH sessions start in /root. runuser keeps the caller's cwd; Podman as
# Platform User then fails with "cannot chdir to /root". stderr is discarded
# below, so that failure looked like LogDriver=''.
platform_home="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
cd "${platform_home:-/}" || cd /
uid_num="$(id -u "${USER_NAME}")"
runtime="/run/user/${uid_num}"
platform_user_env=(
  env
  "XDG_RUNTIME_DIR=${runtime}"
  "DBUS_SESSION_BUS_ADDRESS=unix:path=${runtime}/bus"
)
if ! runuser -u "${USER_NAME}" -- "${platform_user_env[@]}" \
  journalctl --user -n 0 --no-pager >/dev/null 2>&1; then
  echo "Platform journal: live probe failed — user journal not openable (ADR-0050)" >&2
  exit 1
fi
log_driver="$(
  runuser -u "${USER_NAME}" -- "${platform_user_env[@]}" \
    podman info --format '{{.Host.LogDriver}}' 2>/dev/null || true
)"
if [[ "${log_driver}" != "journald" ]]; then
  echo "Platform journal: live probe failed — Podman LogDriver is '${log_driver}', expected journald (ADR-0050)" >&2
  exit 1
fi
