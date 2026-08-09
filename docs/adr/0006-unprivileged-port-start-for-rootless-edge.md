# Unprivileged port start 80 for rootless edge binds

Every Host’s Initial Host Provisioning sets `net.ipv4.ip_unprivileged_port_start=80` so an unprivileged user can bind 80/443. Acceptance Tests assert that value. We accept that any local UID may bind ports 80–1023; ports below 80 (e.g. SSH) stay privileged. While Propraetor has only one Host shape, the floor applies to all Hosts; a later non-edge Host role may omit it deliberately rather than inherit this by silence.

**Sysctl over nftables redirect (80→high, 443→high):** one Host rule, no second hop to debug, no host-firewall footgun on the backend ports. Cost is a wider local bind band than “only 80/443”; on a single-tenant public Host that trade is acceptable. Publish-port allowlisting in deploy config was considered and dropped — it does not block `bind()` at runtime.

**Rootful edge / rootful Podman over this:** rejected for the intended workload shape. Propraetor installs only user Quadlets (rootless Podman) via Workload / Component Setup after **Deploy** (ADR-0041); system Quadlets under `/etc/containers/systemd/` are out of that policy. Container uid 0 under rootless remains allowed (Host root is not implied). Platform User creation moved to Initial Host Provisioning in ADR-0008 (supersedes the earlier “defer Host users until deploy” note here).

**Unchanged from ADR-0004:** no Quadlet units in Initial Host Provisioning; IHP produces **Substrate**, not Workloads.
