# Host Volume mount without scripts_user

The Host Volume must end up mounted at `/var/lib/host-volume` even when DigitalOcean vendor scripts fail in cloud-init final and skip `scripts_user` / `runcmd` (same failure class as Platform User linger — see [ADR-0008](0008-prefect-user-in-initial-host-provisioning.md)). Mount convergence stays an **Initial Host Provisioning** outcome ([ADR-0009](0009-host-volume.md), [ADR-0010](0010-component-setup-and-host-volume-layout.md)): a config-stage systemd oneshot (installed via `write_files`) waits for the by-id device, reclaims any foreign mount of that device (provider `/mnt/…` is not the Propraetor contract), then mounts from fstab. Start without `runcmd`: a config-stage `tmpfiles.d` WantedBy symlink (write_files cannot create symlinks) plus a config-stage udev `SYSTEMD_WANTS` rule so late attach after Host create still starts the unit; the oneshot uses `Restart=on-failure` with a start-limit so attempts retry until the shared budget expires. **IHP Done** only asserts the outcome with a bounded `findmnt` retry aligned to that same retry budget; it does not mount and does not `systemctl start` the unit. ensure-components never mounts. On reclaim `umount` EBUSY, fail the attempt and let restart retry — no lazy/force umount. Failure messaging stays outcome-focused (mount missing after wait, point at the unit), not a Host diagnostics dump.

**Config-stage oneshot over runcmd wait:** runcmd never runs when vendor final fails; linger already moved to config-stage files for that reason.

**IHP-owned convergence over ensure-components / IHP Done healing:** a second mount policy would blur the Substrate / IHP contract and hide IHP bugs.

**udev + tmpfiles enablement over runcmd-only start:** post-create attach is designed; the unit must enter its restart loop without `scripts_user`.

**Restart-on-failure over a single long wait:** one timed oneshot can fail before the device exists.

**Reclaim foreign mounts over fail-closed or bind/move:** the provider automount is expected on first attach and must not leave the device busy at the wrong path.
