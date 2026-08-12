# Container runtimes: value propositions through the years

**Researched:** 2026-08-11  
**Question:** What problem was Docker supposed to solve? Compare LXC/LXD (and Incus), Docker (incl. Compose), and Podman (incl. Quadlets) as local/single-host container run & supervision models, how their value propositions changed over time, and whether “Podman+Quadlets makes Docker look like a superfluous abstraction hiding details behind Compose sugar” holds.  
**Scope:** Local / single-host packaging, run, networking, and supervision. Kubernetes and multi-host orchestration appear only where they reshaped the value landscape (OCI, Swarm legacy, Compose Spec). Not a Propraetor design doc.  
**Method:** Primary sources only — linuxcontainers.org / LXC / Incus / LXD materials; docs.docker.com and first-party Docker blog/press; docs.podman.io and containers/podman README/releases; OCI / opencontainers.org; containerd and runc READMEs; systemd generator docs via Quadlet man pages; Red Hat first-party Podman/Quadlet posts. Secondary posts used only as leads and verified against owning sources. No invented timelines.

---

## Verdict

Docker’s founding problem, as restated by Docker itself, was developer friction: **“shipping code to the server is hard.”** The product response was not inventing OS containers, but packaging kernel isolation primitives into a portable **image + CLI + daemon** workflow so developers could build, share, and run the same unit across machines ([Docker nine-year post](https://www.docker.com/blog/docker-nine-years-young/), [2019 “next chapter”](https://www.docker.com/blog/docker-next-chapter-advancing-developer-workflows-for-modern-apps/), [current overview](https://docs.docker.com/get-started/docker-overview/)). That bet won: the image/runtime ideas became industry standards via the OCI ([OCI overview](https://opencontainers.org/about/overview/)), and “run this image” stopped being Docker-specific.

For a **systemd-centric solo or small-host operator**, the thesis mostly holds: once OCI images and runtimes are commodity, **Compose is a developer-facing multi-service DSL** that deliberately abstracts host supervision, while **Podman Quadlets are a thin generator over systemd** — they expose `After=`/`Wants=`, cgroup split, `Type=notify`, and boot integration instead of hiding them ([Compose docs](https://docs.docker.com/compose/), [Compose Spec](https://compose-spec.io/), [podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html), [Red Hat Quadlet post](https://www.redhat.com/en/blog/quadlet-podman)). Docker is not worthless in 2026 — Hub, Desktop, BuildKit, and Compose remain strong **developer product** surfaces ([Docker Hub](https://docs.docker.com/docker-hub/), [Desktop](https://docs.docker.com/desktop/), [BuildKit](https://docs.docker.com/build/buildkit/)) — but on a Linux host where systemd already owns process supervision, Docker Engine + Compose are often an extra control plane, not a unique runtime capability.

---

## Problem space

“Running a container” mixes **kernel features** and **userland tooling**:

| Layer | What it is | Who owns it |
| --- | --- | --- |
| Isolation | Namespaces (mount, pid, net, ipc, uts, user), cgroups, capabilities, seccomp, LSM (AppArmor/SELinux) | Linux kernel; exposed by LXC, Docker, Podman, runc/crun ([LXC introduction](https://linuxcontainers.org/lxc/introduction/), [Docker underlying tech](https://docs.docker.com/get-started/docker-overview/), [runc README](https://github.com/opencontainers/runc/blob/main/README.md)) |
| Packaging | Immutable layered filesystem + config (command, env, ports) as a shareable artifact | Historically Docker image model; standardized as OCI Image Spec ([OCI overview](https://opencontainers.org/about/overview/), [Docker images](https://docs.docker.com/get-started/docker-overview/)) |
| Runtime | Create namespaces/cgroups, pivot root, start process from an OCI bundle | Low-level OCI runtimes (`runc`, `crun`); engines call them ([runc](https://github.com/opencontainers/runc/blob/main/README.md), [Podman README](https://github.com/containers/podman/blob/main/README.md)) |
| Engine / UX | Pull/push, build, networks, volumes, CLI/API familiarity | Docker Engine (client ↔ `dockerd`), Podman/libpod, LXD/Incus for **system** containers ([Docker architecture](https://docs.docker.com/get-started/docker-overview/), [Podman overview](https://docs.podman.io/en/latest/), [Incus introduction](https://linuxcontainers.org/incus/introduction/)) |
| Supervision | Keep processes up across reboot, restart on failure, ordered deps, logs | Host init — on most Linux servers, **systemd**; alternatively a container daemon or orchestrator ([Quadlet / systemd generator](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html), [runc + systemd example](https://github.com/opencontainers/runc/blob/main/README.md)) |
| Multi-container local apps | Declare N services, shared nets/volumes, one “up” | Compose YAML vs Quadlet `.container`/`.pod`/`.network` units vs LXD/Incus profiles/instances ([Compose](https://docs.docker.com/compose/), [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)) |

Critical distinction used below: **application containers** (one process / one app image — Docker/Podman default story) vs **system containers** (full OS userspace sharing the host kernel — LXC/LXD/Incus primary story) ([Incus: containers and VMs](https://linuxcontainers.org/incus/introduction/), [Canonical LXD](https://ubuntu.com/lxd)).

---

## Timeline / value proposition arcs

### LXC → LXD → Incus (OS containers, then cloud-like daemon)

- **~2008 — LXC as userspace for kernel containment.** LXC’s git history records an “Initial revision” on **2008-08-06** ([lxc/lxc commit](https://github.com/lxc/lxc/commit/5e97c3fcce787a5bc0f8ceef43aa3e05195b480a)). Official positioning today: “userspace interface for the Linux kernel containment features” to create an environment “as close as possible to a standard Linux installation but without the need for a separate kernel,” using namespaces, cgroups, capabilities, seccomp, AppArmor/SELinux ([LXC introduction](https://linuxcontainers.org/lxc/introduction/)).
- **Value then:** make OS-level containers operable without a hypervisor — closer to chroot+isolation than to “ship my app as a tarball.”
- **2014-11-04 — LXD announced.** Stéphane Graber’s post on `lxc-devel` (same day as the OpenStack Summit announcement): daemon with authenticated REST API (unix + HTTPS), image-based workflow, unprivileged by default, snapshots/migration goals, simpler CLI — explicitly framed as improving LXC UX and multi-host management ([lxc-devel announcement](https://lists.linuxcontainers.org/pipermail/lxc-devel/2014-November/010819.html)).
- **2023-07-04 — LXD leaves linuxcontainers.org for Canonical;** community fork **Incus** remains under Linux Containers ([LXD move notice](https://linuxcontainers.org/lxd/introduction/), [Incus introduction](https://linuxcontainers.org/incus/introduction/)).
- **Value now (Incus/LXD):** “next-generation system container, application container, and virtual machine manager” with cloud-like image/API UX; system containers still the differentiator vs Docker/Podman ([Incus](https://linuxcontainers.org/incus/introduction/), [Canonical LXD](https://ubuntu.com/lxd)).

### Docker (app packaging + developer workflow + daemon)

- **2013-03-15 — Public debut at PyCon.** Docker’s own retrospectives: Solomon Hykes framed the problem as shipping to the server being hard; the answer was abstracting kernel container primitives, a developer CLI, and an immutable portable image format so `docker run hello-world` was enough ([nine years](https://www.docker.com/blog/docker-nine-years-young/), [next chapter 2019](https://www.docker.com/blog/docker-next-chapter-advancing-developer-workflows-for-modern-apps/), [11 years](https://www.docker.com/blog/docker-11-year-anniversary/)).
- **~2013–2016 — Rise.** Value proposition: separate app from infrastructure; same artifact from laptop to server; denser than VMs; lifecycle tooling around images/containers/networks/volumes; **client–server via `dockerd`** ([Docker overview](https://docs.docker.com/get-started/docker-overview/)).
- **2014 — Compose v1.** Python `docker-compose`; multi-container apps as one YAML + one command ([Compose history](https://docs.docker.com/compose/intro/history/)).
- **2015-06-22 — OCI founded;** Docker donates format/runtime (**runC**) as cornerstone ([OCI overview](https://opencontainers.org/about/overview/)). Runtime/image cease to be proprietary moats.
- **containerd path:** Docker Engine embeds containerd; project accepted to CNCF **2017-03-29** (incubating), graduated **2019-02-28** ([CNCF containerd](https://www.cncf.io/projects/containerd/)). containerd positions itself as an industry-standard runtime **daemon** meant to be embedded, not an end-user CLI ([containerd README](https://github.com/containerd/containerd/blob/main/README.md)). Docker 1.11+ already used containerd ([containerd 1.0 release notes](https://github.com/containerd/containerd/releases/tag/v1.0.0)).
- **2019 — Docker company refocus** on developer workflows (Desktop, Hub, Compose) after the ecosystem shifted orchestration to Kubernetes ([next chapter](https://www.docker.com/blog/docker-next-chapter-advancing-developer-workflows-for-modern-apps/)).
- **2020-04-07 — Compose Specification** opened as a community standard for multi-container apps ([announcing Compose Spec](https://www.docker.com/blog/announcing-the-compose-specification/), [compose-spec README](https://github.com/compose-spec/compose-spec/blob/master/README.md) — Created 2020-01-02).
- **Docker Engine 20.10 — rootless mode graduates** from experimental ([20.10 release notes](https://docs.docker.com/engine/release-notes/20.10/)); docs: run daemon and containers as non-root inside a user namespace ([rootless mode](https://docs.docker.com/engine/security/rootless/)). Rootless arrives **as a mode of the daemon**, not by removing it.
- **Compose V2 GA 2022-04-26** (`docker compose`, Go, Compose Spec) ([Compose V2 GA](https://www.docker.com/blog/announcing-compose-v2-general-availability/), [history](https://docs.docker.com/compose/intro/history/)).
- **Value now:** still “build, share, run” — but differentiation is **product/ecosystem** (Hub, Desktop, BuildKit, Scout, etc.), not exclusive ownership of containers ([overview](https://docs.docker.com/get-started/docker-overview/), [11-year post](https://www.docker.com/blog/docker-11-year-anniversary/)).

### Podman (daemonless OCI engine + systemd)

- **RHEL 8 Beta (announced 2018-11-15):** Red Hat ships Buildah / Podman / Skopeo as a daemonless container toolkit ([RHEL 8 Beta developer blog](https://developers.redhat.com/blog/2018/11/15/red-hat-enterprise-linux-8-beta-is-here)).
- **Podman 1.0.0 — 2019-01-11** ([release](https://github.com/containers/podman/releases/tag/v1.0.0)).
- **Stated scope:** OCI/Docker images; full container lifecycle; pods; **rootless**; Docker-compatible CLI; **“No manager daemon”**; optional REST API; systemd-friendly fork/exec model ([Podman README](https://github.com/containers/podman/blob/main/README.md), [docs.podman.io](https://docs.podman.io/en/latest/), [Red Hat “what is Podman”](https://www.redhat.com/en/topics/containers/what-is-podman)).
- **Daemon critique (first-party):** no single root daemon as SPOF; better audit attribution (fork/exec); rootless from day one ([Red Hat Podman features post](https://www.redhat.com/en/blog/podman-container-intro)).
- **systemd path:** `podman generate systemd` (history notes from **2019**, pod support **2019-08**) — now **deprecated** in favor of Quadlets ([podman-generate-systemd(1)](https://docs.podman.io/en/latest/markdown/podman-generate-systemd.1.html)).
- **Podman 4.4.0 — 2023-02-01:** “Introduce Quadlet” ([release](https://github.com/containers/podman/releases/tag/v4.4.0)); Red Hat blog **2023-02-17**: Quadlet as systemd generator; “Think of it as a Compose or Kubernetes file but for systemd” ([Quadlet post](https://www.redhat.com/en/blog/quadlet-podman)).
- **Value now:** OCI engine that treats the host’s **init system** as the long-lived supervisor, not a parallel container daemon ([README](https://github.com/containers/podman/blob/main/README.md), [podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)).

### Landscape shift (why value props moved)

| Shift | Effect on “who has the moat” |
| --- | --- |
| OCI runtime + image specs (2015+) | Low-level run/format become interchangeable; engines compete on UX, security model, supervision ([OCI](https://opencontainers.org/about/overview/)) |
| containerd as shared runtime substrate | Docker Engine becomes one consumer among many; K8s path uses CRI on containerd ([containerd README](https://github.com/containerd/containerd/blob/main/README.md), [CNCF](https://www.cncf.io/projects/containerd/)) |
| Kubernetes wins cluster orchestration | Docker Swarm remains in Engine docs but is no longer the industry default for scale-out ([Swarm mode](https://docs.docker.com/engine/swarm/); Docker itself pointed developers at K8s in 2019 ([next chapter](https://www.docker.com/blog/docker-next-chapter-advancing-developer-workflows-for-modern-apps/))) |
| Daemonless + rootless + systemd | Host-native supervision becomes a first-class alternative to `dockerd` for single-node services ([Podman](https://github.com/containers/podman/blob/main/README.md), [Quadlet](https://www.redhat.com/en/blog/quadlet-podman)) |

---

## Comparison table

| Dimension | LXC / LXD / Incus | Docker Engine (+ Compose) | Podman (+ Quadlets) |
| --- | --- | --- | --- |
| Primary unit | **System container** (full OS) or VM; Incus also application containers ([Incus](https://linuxcontainers.org/incus/introduction/), [LXC](https://linuxcontainers.org/lxc/introduction/)) | **Application container** from image ([overview](https://docs.docker.com/get-started/docker-overview/)) | **Application container** / pod from OCI/Docker images ([README](https://github.com/containers/podman/blob/main/README.md)) |
| Daemon model | LXC: tools/lib; LXD/Incus: **central daemon + REST API** ([LXD announce](https://lists.linuxcontainers.org/pipermail/lxc-devel/2014-November/010819.html), [Incus](https://linuxcontainers.org/incus/introduction/)) | **Required `dockerd`** client–server ([architecture](https://docs.docker.com/get-started/docker-overview/)) | **No manager daemon** for normal CLI; optional `podman system service` ([README](https://github.com/containers/podman/blob/main/README.md), [docs](https://docs.podman.io/en/latest/)) |
| Rootless | LXD/Incus emphasize unprivileged/secure-by-default system containers ([LXD announce](https://lists.linuxcontainers.org/pipermail/lxc-devel/2014-November/010819.html), [Canonical LXD](https://ubuntu.com/lxd)) | Rootless = **rootless dockerd** in user NS ([rootless docs](https://docs.docker.com/engine/security/rootless/); graduated 20.10 ([notes](https://docs.docker.com/engine/release-notes/20.10/))) | Rootless as core design; no setuid binary required ([README](https://github.com/containers/podman/blob/main/README.md), [Red Hat](https://www.redhat.com/en/topics/containers/what-is-podman)) |
| Image format | Image-based instances (distro images); not the same as “Dockerfile app image” default story ([Incus](https://linuxcontainers.org/incus/introduction/)) | Docker/OCI images; Hub by default ([overview](https://docs.docker.com/get-started/docker-overview/), [Hub](https://docs.docker.com/docker-hub/)) | OCI and Docker images ([README](https://github.com/containers/podman/blob/main/README.md)) |
| Multi-container local apps | Profiles, multiple instances, clustering (LXD/Incus scale story) ([Incus features](https://linuxcontainers.org/incus/introduction/)) | **Compose** YAML → create/start stack ([Compose](https://docs.docker.com/compose/), [Spec](https://compose-spec.io/)) | **Quadlet** `.container`/`.pod`/`.network`/… → systemd services; also pods / kube play ([podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)) |
| systemd integration | Orthogonal (manage LXD/Incus daemon as a service; instances have their own lifecycle) | Containers supervised by **dockerd**; Compose talks to Engine API — not systemd-native unit generation as first-class DX | **First-class:** generator produces units; `[Service]`/`[Install]` pass through; cgroup v2 required for Quadlet ([podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)) |
| Ecosystem / DX | Cloud-like instance UX; Ubuntu/Canonical productization for LXD ([ubuntu.com/lxd](https://ubuntu.com/lxd)) | Desktop, Hub, BuildKit, Compose Spec reference impl ([Desktop](https://docs.docker.com/desktop/), [Hub](https://docs.docker.com/docker-hub/), [BuildKit](https://docs.docker.com/build/buildkit/), [compose-spec](https://github.com/compose-spec/compose-spec/blob/master/README.md)) | Docker-compatible CLI; modular Buildah/Skopeo; Podman Desktop ([README](https://github.com/containers/podman/blob/main/README.md), [Red Hat](https://www.redhat.com/en/topics/containers/what-is-podman)) |
| Security posture claims (docs) | Unprivileged containers, resource limits, auth ([Incus](https://linuxcontainers.org/incus/introduction/), [LXD](https://ubuntu.com/lxd)) | Isolation via namespaces; rootless mitigates daemon/runtime vulns ([overview](https://docs.docker.com/get-started/docker-overview/), [rootless](https://docs.docker.com/engine/security/rootless/)) | Daemonless + rootless; SELinux labels called out by Red Hat ([what is Podman](https://www.redhat.com/en/topics/containers/what-is-podman), [features post](https://www.redhat.com/en/blog/podman-container-intro)) |

---

## Compose vs Quadlets

**Compose** (product + Spec) optimizes for **developer-defined application graphs**: services, networks, volumes in one YAML; “create and start all of the services from your configuration file” with one command ([Compose](https://docs.docker.com/compose/)). The Spec is explicitly **developer-focused** and **platform-agnostic** — local engine, Kubernetes translations, cloud mappings ([compose-spec.io](https://compose-spec.io/), [Spec README use cases](https://github.com/compose-spec/compose-spec/blob/master/README.md)). That is the sugar: operators do not write `After=network-online.target`, cgroup delegation, or notify readiness; the Compose implementation and Engine own that mapping.

**Quadlets** optimize for **host service management**. Files use systemd unit syntax plus a Podman section (`[Container]`, `[Pod]`, …). A **systemd generator** emits real `.service` units at daemon-reload/boot; non-Podman sections pass through untouched — dependencies, resource limits, install targets ([podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)). Red Hat’s framing: hide *Podman/systemd integration complexity*, not systemd itself; “Compose or Kubernetes file but **for systemd**” ([Quadlet post](https://www.redhat.com/en/blog/quadlet-podman)). Generated services use patterns like `Type=notify`, `cgroups=split`, `sdnotify=conmon` (shown in the same post’s dry-run output).

| | Compose | Quadlet |
| --- | --- | --- |
| Abstraction target | Multi-container **app** on a container engine | Container workload as a **systemd unit** |
| What stays visible | Service graph, image names, ports, env | systemd dependency/ordering, cgroup/service type, journalctl |
| What is hidden | Host init, Engine internals | Long `podman run` / generate-systemd boilerplate |
| Failure domain | Engine + Compose project lifecycle | systemd unit lifecycle (restart policies, boot targets) |

So: Compose is sugar over **engine orchestration of containers**. Quadlet is sugar over **wiring containers into systemd** — which *reveals* supervision/cgroup reality rather than replacing it. Calling Compose “superfluous” is fair **when the operator’s real control plane is already systemd**; it is unfair when the goal is a portable, engine-centric app definition across laptops and clouds ([Spec use cases](https://github.com/compose-spec/compose-spec/blob/master/README.md)).

`podman generate systemd` was the transitional “emit a unit from a live container” approach; upstream now says use Quadlets; generate-systemd gets urgent fixes only ([podman-generate-systemd(1)](https://docs.podman.io/en/latest/markdown/podman-generate-systemd.1.html)).

---

## What Docker still sells (2026)

Commodity (not unique to Docker Engine anymore):

- Running OCI images via an OCI runtime ([OCI](https://opencontainers.org/about/overview/), [runc](https://github.com/opencontainers/runc/blob/main/README.md)).
- CLI familiarity (Podman deliberately aliases) ([Podman docs](https://docs.podman.io/en/latest/)).
- Rootless containers (Podman earlier; Docker as rootless **daemon**) ([Podman README](https://github.com/containers/podman/blob/main/README.md), [Docker rootless](https://docs.docker.com/engine/security/rootless/)).

Still distinctive product surfaces (cite Docker’s own docs/positioning):

1. **Docker Hub** — default public registry, private repos, trusted content, integrations ([Hub](https://docs.docker.com/docker-hub/)).
2. **Docker Desktop** — one-click Mac/Windows/Linux DX: Engine, Compose, Kubernetes, GUI, volume/port defaults ([Desktop](https://docs.docker.com/desktop/), [overview](https://docs.docker.com/get-started/docker-overview/)).
3. **BuildKit** — default builder backend; parallel graph, better context transfer, LLB, cache export ([BuildKit](https://docs.docker.com/build/buildkit/)).
4. **Compose Spec + reference implementation** — developer-centric multi-container definition; Docker Compose listed as reference implementation ([compose-spec README](https://github.com/compose-spec/compose-spec/blob/master/README.md), [Compose](https://docs.docker.com/compose/)).
5. **Swarm mode** — still documented as Engine-native clustering; Classic Swarm is abandoned. Relevant as legacy/optional, not as the industry default ([Swarm mode](https://docs.docker.com/engine/swarm/)).
6. **Commercial / company focus** — since 2019, Docker Inc. positions around developer inner-loop products rather than owning orchestration ([next chapter](https://www.docker.com/blog/docker-next-chapter-advancing-developer-workflows-for-modern-apps/), [11 years](https://www.docker.com/blog/docker-11-year-anniversary/)). Moby remains the open upstream “Lego set”; Docker Desktop is the supported end-user product path ([Moby README](https://github.com/moby/moby/blob/master/README.md)).

---

## Assessment for a systemd-centric solo / small-host operator

**Recommendation framing**

1. **If the host is Linux and systemd is already the supervisor**, prefer **Podman + Quadlets** for long-lived services. You get OCI images without a permanent root (or rootless) container daemon in the critical path, and unit files that speak the host’s native dependency and cgroup language ([README](https://github.com/containers/podman/blob/main/README.md), [podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html), [Quadlet post](https://www.redhat.com/en/blog/quadlet-podman)).
2. **Treat Compose as a DX/portability format**, not as the production supervision model on that host. Keep Compose where developers share stacks or where you intentionally want engine-managed projects; translate durable services to Quadlets (or run Compose against Podman’s Docker-compatible API only if you accept the Engine-shaped lifecycle) ([Compose](https://docs.docker.com/compose/), [Red Hat on Docker compatibility](https://www.redhat.com/en/blog/podman-container-intro)).
3. **Do not use LXC/LXD/Incus as a drop-in for “Docker app containers.”** Use them when you need **system containers / VM-like instances** with a cloud-style API ([Incus](https://linuxcontainers.org/incus/introduction/), [LXC](https://linuxcontainers.org/lxc/introduction/)).
4. **Keep Docker Desktop/Hub/BuildKit in the loop** for laptop DX and image ecosystem even if production on the small host is Podman — that split matches how Docker’s own value moved after OCI/K8s ([next chapter](https://www.docker.com/blog/docker-next-chapter-advancing-developer-workflows-for-modern-apps/)).

**On the thesis:** For this operator profile, Docker Engine + Compose *are* largely a superfluous second control plane **for runtime/supervision**. They remain non-superfluous as **packaging culture, registry gravity, and developer tooling**. The “syntactic sugar” critique sticks to **Compose-as-host-orchestrator**, not to “containers were a bad idea” or “images are useless.”

---

## Sources

- [LXC introduction](https://linuxcontainers.org/lxc/introduction/)
- [lxc/lxc initial revision (2008-08-06)](https://github.com/lxc/lxc/commit/5e97c3fcce787a5bc0f8ceef43aa3e05195b480a)
- [LXD announcement on lxc-devel (2014-11-04)](https://lists.linuxcontainers.org/pipermail/lxc-devel/2014-November/010819.html)
- [LXD move to Canonical / Incus pointer](https://linuxcontainers.org/lxd/introduction/)
- [Incus introduction](https://linuxcontainers.org/incus/introduction/)
- [Canonical LXD product page](https://ubuntu.com/lxd)
- [Docker overview](https://docs.docker.com/get-started/docker-overview/)
- [Docker: Nine Years YOUNG (2022-03-15)](https://www.docker.com/blog/docker-nine-years-young/)
- [Docker’s Next Chapter (2019-11-13)](https://www.docker.com/blog/docker-next-chapter-advancing-developer-workflows-for-modern-apps/)
- [11 Years of Docker (2024-03-21)](https://www.docker.com/blog/docker-11-year-anniversary/)
- [Docker Compose](https://docs.docker.com/compose/)
- [History and development of Docker Compose](https://docs.docker.com/compose/intro/history/)
- [Announcing the Compose Specification (2020-04-07)](https://www.docker.com/blog/announcing-the-compose-specification/)
- [compose-spec.io](https://compose-spec.io/)
- [compose-spec README](https://github.com/compose-spec/compose-spec/blob/master/README.md)
- [Announcing Compose V2 GA](https://www.docker.com/blog/announcing-compose-v2-general-availability/)
- [Docker Hub](https://docs.docker.com/docker-hub/)
- [Docker Desktop](https://docs.docker.com/desktop/)
- [BuildKit](https://docs.docker.com/build/buildkit/)
- [Swarm mode](https://docs.docker.com/engine/swarm/)
- [Rootless mode](https://docs.docker.com/engine/security/rootless/)
- [Docker Engine 20.10 release notes](https://docs.docker.com/engine/release-notes/20.10/)
- [Moby README](https://github.com/moby/moby/blob/master/README.md)
- [OCI overview](https://opencontainers.org/about/overview/)
- [opencontainers/runc README](https://github.com/opencontainers/runc/blob/main/README.md)
- [containerd README](https://github.com/containerd/containerd/blob/main/README.md)
- [CNCF containerd project page](https://www.cncf.io/projects/containerd/)
- [containerd 1.0.0 release](https://github.com/containerd/containerd/releases/tag/v1.0.0)
- [Podman docs home](https://docs.podman.io/en/latest/)
- [containers/podman README](https://github.com/containers/podman/blob/main/README.md)
- [Podman v1.0.0](https://github.com/containers/podman/releases/tag/v1.0.0)
- [Podman v4.4.0 (Quadlet)](https://github.com/containers/podman/releases/tag/v4.4.0)
- [podman-systemd.unit(5)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
- [podman-generate-systemd(1)](https://docs.podman.io/en/latest/markdown/podman-generate-systemd.1.html)
- [RHEL 8 Beta — container tools (2018-11-15)](https://developers.redhat.com/blog/2018/11/15/red-hat-enterprise-linux-8-beta-is-here)
- [What is Podman? (Red Hat)](https://www.redhat.com/en/topics/containers/what-is-podman)
- [5 Podman features… (Red Hat, 2023-03-09)](https://www.redhat.com/en/blog/podman-container-intro)
- [Make systemd better for Podman with Quadlet (2023-02-17)](https://www.redhat.com/en/blog/quadlet-podman)
