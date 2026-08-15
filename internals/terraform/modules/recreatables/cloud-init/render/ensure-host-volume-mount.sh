#!/usr/bin/env bash
# Host-only: converge Host Volume at /host-volume (ADR-0031 / ADR-0054).
# Usage: ensure-host-volume-mount.sh /dev/disk/by-id/scsi-0DO_Volume_<name>
# Idempotent. On foreign mount of the device, umount then mount from fstab.
# EBUSY on umount fails the attempt (systemd Restart=on-failure retries).
set -euo pipefail

DEVICE="${1:-}"
TARGET="${HOST_VOLUME_TARGET:-/host-volume}"
# Per-attempt device wait; longer horizon is Restart=on-failure + start-limit.
WAIT_SECONDS="${HOST_VOLUME_DEVICE_WAIT_SECONDS:-20}"

if [[ -z "${DEVICE}" ]]; then
  echo "usage: $0 /dev/disk/by-id/scsi-0DO_Volume_<name>" >&2
  exit 2
fi

deadline=$((SECONDS + WAIT_SECONDS))
while [[ ! -e "${DEVICE}" ]]; do
  if ((SECONDS >= deadline)); then
    echo "Host Volume device missing: ${DEVICE}" >&2
    exit 1
  fi
  sleep 1
done

self_enable() {
  # WantedBy symlink without runcmd (ADR-0031). Skip in tests (non-canonical TARGET).
  if [[ "${TARGET}" != "/host-volume" ]]; then
    return 0
  fi
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sfn /etc/systemd/system/host-volume.service \
    /etc/systemd/system/multi-user.target.wants/host-volume.service
}

# Already the Propraetor mountpoint?
if findmnt --mountpoint "${TARGET}" >/dev/null 2>&1; then
  self_enable
  exit 0
fi

# Reclaim provider (or other) mounts of this device away from TARGET.
real_device="$(readlink -f "${DEVICE}" 2>/dev/null || true)"
while true; do
  foreign="$(findmnt -n -o TARGET --source "${DEVICE}" 2>/dev/null || true)"
  if [[ -z "${foreign}" && -n "${real_device}" ]]; then
    foreign="$(findmnt -n -o TARGET --source "${real_device}" 2>/dev/null || true)"
  fi
  foreign="$(printf '%s\n' "${foreign}" | head -n1 | tr -d '\r')"
  if [[ -z "${foreign}" ]]; then
    break
  fi
  if [[ "${foreign}" == "${TARGET}" ]]; then
    break
  fi
  umount "${foreign}"
done

mkdir -p "${TARGET}"
mount "${TARGET}"

if ! findmnt --mountpoint "${TARGET}" >/dev/null 2>&1; then
  echo "Host Volume mount ${TARGET} missing after mount" >&2
  exit 1
fi

self_enable
