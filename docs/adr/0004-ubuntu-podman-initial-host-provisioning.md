# Ubuntu 26.04 Host Image; distro Podman via Initial Host Provisioning

Public Hosts pin Ubuntu 26.04 LTS. The container engine is Podman from Ubuntu’s packages, installed only through Initial Host Provisioning (engine package only — no `package_update`, no full `package_upgrade`, no Quadlet units). Apt indexes from the Host Image are enough to install; refresh on create may return once Propraetor is out of dev-only iteration.

**26.04 over older LTS:** newest LTS keeps distro Podman (and thus Quadlets) as current as Ubuntu LTS allows — closer to a mature Quadlets implementation without leaving the distro path. We deliberately skip manual/upstream installs (e.g. chasing Podman 6.x): any gain isn’t worth ongoing maintenance if upstream and the LTS Host Image drift apart.

**Podman over Docker:** daemonless (no privileged daemon as a standing attack surface), rootless-capable for unprivileged users, and Quadlets use systemd instead of a Docker-specific stack — skills stay transferable.

**Initial Host Provisioning over Ansible (etc.):** IHP produces **Substrate** (engine, later Platform User / ports / Host Volume mount) and stays oblivious to Workloads; first-boot setup stays minimal and does not justify a config-management tool.
