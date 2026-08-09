# Mandatory Host Volume on public Hosts

**Amended by [ADR-0025](0025-lifecycle-convergence-by-structural-class.md):** Park/Teardown durability (supersedes ADR-0016). **Amended by [ADR-0019](0019-environments.md):** Cloud Project assignment is Environment-namespaced.

Public Hosts get a mandatory **Host Volume**: a Stack-owned 1 GiB block volume attached at Host create (`volume_ids`), assigned to the Environment’s Cloud Project (e.g. `propraetor-<slug>`), formatted `ext4` on first volume create only. It survives Host rebuilds and **Park**; **Teardown** removes it with the rest of the Stack (ADR-0025). Initial Host Provisioning mounts it at `/var/lib/host-volume` (fstab via `/dev/disk/by-id/…`, `defaults,nofail,discard,noatime`); the mount root stays root-owned. How that mount converges without depending on cloud-init `scripts_user` (and how late attach after Park is handled) is [ADR-0031](0031-host-volume-mount-without-scripts-user.md). Component source/data layout under the mount is defined in ADR-0010 (this ADR only established the volume + mount); Host Volume `internals/` / `data/` split is ADR-0041. Acceptance Tests assert State (size, attachment, Cloud Project URN) and a live mounted filesystem at `/var/lib/host-volume`.

**One Host Volume over per-Workload volumes:** durable bytes are a Propraetor Host concern (parallel to Reserved IP for address). Split volumes later only if a Workload needs a separate lifecycle or isolation.

**Survive Host recreate and Park; remove on Teardown:** Host rebuilds and Park keep the volume; only explicit Teardown wipes it (ADR-0025). Earlier deferral of “durable beyond Destroy” is closed.

**`volume_ids` at Host create over post-create attachment:** the block device must be present for Initial Host Provisioning. Provider auto-mount under `/mnt/<volume-name>` happens only on first volume create and is not the Propraetor contract — fstab to `/var/lib/host-volume` is, including after Host recreate when the provider will not auto-mount again.

**Mount + fstab in Initial Host Provisioning over resource-only or deploy-time mount:** a mandatory Host Volume that nobody mounts is incomplete; IHP establishes the mount as part of **Substrate** and does not install Workloads or Quadlets (ADR-0004).

**1 GiB, grow later:** smallest provider size; expand when a Workload needs bulk disk. Mount root stays root-owned; trees under it are Platform User–owned (ADR-0010).
