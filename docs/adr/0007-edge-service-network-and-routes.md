# Edge, Service Network, and Workload Routes

Public Hosts get a mandatory **Edge** (Propraetor Component — HTTP/HTTPS front door) and a Propraetor-owned **Service Network** (**Fabric**, applied by Fabric Setup — not a Component peer of Edge). Optional **Workloads** join that network and author **Route Declarations** (Edge Component Setup gathers and fulfills). Unit names follow the role (`service-network`, `edge`, `edge-nginx`); repo trees live under `internals/fabric/` + `internals/components/edge/`, with authored units under one `systemd/` bag (ADR-0034 / ADR-0010 / ADR-0054). TLS terminates at the Edge (ACME is Edge-owned and on-demand — ADR-0015); the first drop is HTTP :80 only, with Host bind mounts reserved for Routes and future certs. Empty Edge (no fulfilled Routes) answers with a default 404/444 — not a holding page and not “don’t run.”

**Amended by ADR-0054 / #216 / #218:** unified `systemd/` consumer bag (retired `quadlets/`).

**Edge over peer Workloads on 80/443:** sole entrypoint is a Propraetor invariant, not an accident of one container. Peer publishers would fight the Firewall/Reserved-IP story and ADR-0006’s rootless edge bind.

**Shared Service Network over one Pod for Edge+Workloads, host network, or Host-published Workload ports:** Workloads stay optional and independent; name-based reachability without exposing backends on the Host. The network is its own Propraetor piece so Workloads do not depend on “nginx’s network.”

**Edge Pod + nginx container over a lone container:** keeps Edge units cohesive and leaves room for helpers that share the Pod; ACME execution model is on-demand (ADR-0015), not a standing sidecar. No placeholder/self-signed 443 in the first drop.

**Workload-owned Routes over a monolithic Edge config or dynamic discovery:** each Workload’s Route is an operator-authored Declaration under the Workload tree (ADR-0022 / ADR-0040); Edge Component Setup gathers and fulfills into Domain fronts. Alpine-family nginx image; Host bind mounts for Routes and certs (and ACME webroot — ADR-0015).

**Unchanged from ADR-0004 / ADR-0006:** user Quadlets / rootless only; no Quadlet install in Initial Host Provisioning; IHP produces **Substrate**, not Workloads. Platform User + linger are Initial Host Provisioning (ADR-0008).
