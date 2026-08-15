# Platforms and tools in Propraetor’s niche

**Researched:** 2026-07-26  
**Question:** What products, tools, and projects occupy the same or a similar niche as this repo’s **Propraetor** (self-hosted reusable Host/platform for a solo operator between “repeat infra per small project” and “PaaS lock-in”)?  
**Scope:** Primary sources only (official sites, docs, first-party GitHub READMEs). Secondary listicles used only to discover candidates; claims below are verified on primary pages.

**Method notes:** Niche boundaries taken from this repo’s [`README.md`](../../README.md) and [`CONTEXT.md`](../../CONTEXT.md): thin Workload contract; portable native formats; Host carrier (today VPS + Edge + containers); Park/Apply/Teardown + Durables; vertical scale then graduate; solo-operator smallest model. “Overlap” means sharing that *economic/positioning* niche (own the VPS, avoid managed PaaS bills/lock-in, run many small apps), not feature parity. Prefer ~12 well-sourced candidates over an unverified laundry list.

---

## Verdict

**Closest neighbors fall into two camps:**

1. **Self-hosted “Heroku on your VPS” PaaS** (Coolify, Dokploy, CapRover, Dokku, Piku) — same *economic* niche (reuse one server, skip Railway/Render/Heroku), but they are **thicker app platforms**: UI/git-push lifecycle, platform-owned proxy/SSL, often Docker/Swarm/Traefik under the hood. Exit is “keep containers, lose the automations,” not “thin Manifest + native Quadlets.”
2. **Thin deployers that keep Docker native** (especially **Kamal**) — closest *philosophical* neighbor on lock-in and “use tools you understand,” but they **deploy one app’s containers to servers you already have**; they do not own Host/Reserved-IP/Volume lifecycle, Environments, or a shared Edge/Workload contract the way Propraetor does.

**Propraetor’s distinct bet (from this repo’s own framing):** IaC for a **reusable Host carrier** + a **minimal Workload Manifest**, while Workload runtime config stays in **native formats** (today rootless Quadlets); Park/Durables for cost; graduate Workloads out rather than grow into a general orchestrator. None of the surveyed products publish an equivalent Park/Durables model on primary docs.

---

## How to read “overlap”

| Lens | Propraetor (this repo) | Typical self-hosted PaaS | Kamal-like deployer | Managed PaaS |
| --- | --- | --- | --- | --- |
| Who owns the VM? | Operator (Stack/IaC) | Operator | Operator | Vendor |
| Primary UX | Repo scripts + Manifest | Web UI / `git push` | CLI + `deploy.yml` | Dashboard / CLI |
| Workload declaration | Thin Manifest; runtime in native formats | Buildpacks / Dockerfile / Compose / platform JSON | Dockerfile + Kamal YAML | Dockerfile / buildpacks / platform YAML |
| Proxy / TLS | Propraetor Edge Component | Traefik / nginx owned by platform | kamal-proxy (or similar) | Vendor edge |
| Host lifecycle | Apply / Park / Teardown + Durables | You keep the VPS running (or cloud-managed control plane) | You provision servers elsewhere | Hidden |
| Scaling story | Vertical Host; graduate Workload | Multi-server / Swarm / (sometimes) k3s | Multi-server roles | Autoscaling / regions |
| Exit path | Adaptation of portable pieces | Containers may remain; lose platform magic | Docker images + config you wrote | Rebuild elsewhere |

---

## Bucket A — Self-hosted PaaS (“Heroku on your VPS”)

### Coolify

| | |
| --- | --- |
| **Positioning** | “Open-source & self-hostable alternative to Vercel, Heroku, Netlify and Railway” for deploying sites, DBs, apps, and one-click services on your own server. ([coolify.io](https://coolify.io/), [docs intro](https://coolify.io/docs/get-started/introduction)) |
| **Self-hosted vs managed** | Both: self-host free; **Coolify Cloud** paid (docs: starts at $5/mo) manages Coolify while you still connect your servers over SSH. ([docs intro](https://coolify.io/docs/get-started/introduction)) |
| **How workloads are declared** | Build packs: Nixpacks, Static, **Dockerfile**, **Docker Compose** (compose as “single source of truth” option); Git push/integrations. ([build packs](https://coolify.io/docs/applications/build-packs), [compose KB](https://coolify.io/docs/knowledge-base/docker/compose)) |
| **Abstraction / exit** | Markets “No Vendor Lock-In”: settings stay on your servers; if you stop using Coolify you keep resources but “lose the automations.” Default proxy is **Traefik** (or custom/none). Multi-server: each server has its own proxy; DNS points at the app’s server. ([coolify.io](https://coolify.io/), [server intro](https://coolify.io/docs/knowledge-base/server/introduction)) |
| **Solo-operator signals** | Explicitly pitched as personal Vercel/Railway alternative; SSH + any VPS/Pi; open-source all features. |
| **Scaling** | Single server, multi-server, Docker Swarm; Kubernetes “coming soon” in docs. ([docs intro](https://coolify.io/docs/get-started/introduction)) |
| **vs Propraetor** | Same “own the VPS, avoid PaaS bills” niche; **thicker** control plane (UI, build packs, PR deploys). Does not replace Propraetor’s Stack/Park/Durables Host contract. |

### Dokploy

| | |
| --- | --- |
| **Positioning** | “Open source alternative to Heroku, Vercel, and Netlify”; free self-hostable PaaS using Docker + Traefik. ([docs](https://docs.dokploy.com/docs/core), [self-hosted page](https://dokploy.com/self-hosted-paas)) |
| **Self-hosted vs managed** | Both: self-host free; **Dokploy Cloud** manages the control plane (UI/DB/Redis) while apps stay on your servers (plans marketed from ~$4.50/mo per server). ([self-hosted page](https://dokploy.com/self-hosted-paas)) |
| **How workloads are declared** | Applications (GitHub/Git/Docker/webhooks) and **Docker Compose** / Docker Stack modes; domains via Traefik. ([applications](https://docs.dokploy.com/docs/core/applications), [compose](https://docs.dokploy.com/docs/core/docker-compose)) |
| **Abstraction / exit** | Strong Docker-native story (compose as first-class); advanced Swarm replicas/registry settings. UI still owns deploy lifecycle, domains, monitoring. Exit cost: leave Traefik/Dokploy conventions behind. |
| **Solo-operator signals** | Single-command install; pitched for developers wanting PaaS without Kubernetes. |
| **Scaling** | Multi-server remote deploys; Docker Swarm cluster settings in app advanced config. ([applications](https://docs.dokploy.com/docs/core/applications), GitHub README via [dokploy.com](https://dokploy.com/self-hosted-paas)) |
| **vs Propraetor** | Overlaps Coolify’s niche more than Propraetor’s thin-contract model; Compose-friendly is closer to “native formats” than CapRover’s `captain-definition`, still a full PaaS. |

### CapRover

| | |
| --- | --- |
| **Positioning** | “Scalable, Free and Self-hosted PaaS”; “Deploy apps. Own your infrastructure.” Docker + nginx + Let’s Encrypt + Docker Swarm. ([caprover.com](https://caprover.com/)) |
| **Self-hosted vs managed** | Self-hosted (install via Docker on your server). ([get started](https://caprover.com/docs/get-started.html)) |
| **How workloads are declared** | **`captain-definition` JSON** (templateId, dockerfilePath, dockerfileLines, or imageName); CLI `caprover deploy`; one-click apps via templatized compose subset. **Native `docker-compose.yml` is not fully supported** via Docker API — partial parser / one-click template path. ([captain-definition](https://caprover.com/docs/captain-definition-file.html), [docker-compose](https://caprover.com/docs/docker-compose.html)) |
| **Abstraction / exit** | Homepage claims “No lock-in! Remove CapRover and your apps keep working!” Owns nginx templates and Swarm; captain-definition is CapRover-specific. Compose support is partial (subset of fields). ([caprover.com](https://caprover.com/), [docker-compose](https://caprover.com/docs/docker-compose.html)) |
| **Solo-operator signals** | Dashboard + CLI; DigitalOcean one-click; ~$5 VPS class called out in docs. |
| **Scaling** | Attach nodes; Docker Swarm clustering; nginx load balancing. ([caprover.com](https://caprover.com/)) |
| **vs Propraetor** | Same self-hosted PaaS niche; **thicker** CapRover-owned app format than Propraetor’s thin Manifest + native Quadlets. |

### Dokku

| | |
| --- | --- |
| **Positioning** | “The smallest PaaS implementation you’ve ever seen”; open-source Heroku alternative on a single server of your choice. ([dokku.com](https://dokku.com/)) |
| **Self-hosted vs managed** | Self-hosted (open source; paid “pro” mentioned on homepage for uncovered needs). |
| **How workloads are declared** | `git push`; Herokuish/Cloud Native **buildpacks** or **Dockerfile**; Procfile process types; nginx routing. ([installation docs](https://dokku.com/docs/getting-started/installation/), [Dockerfile builder](https://dokku.com/docs/deployment/builders/dockerfiles/)) |
| **Abstraction / exit** | Markets “No vendor lock-in” / “tools you already know” (Docker). App model is Heroku-like (apps, config, plugins). Dockerfile path is more portable; buildpack path is PaaS-shaped. |
| **Solo-operator signals** | CLI-first, plugin-extensible, long-lived single-host Heroku clone — strong solo fit. |
| **Scaling** | Default: process scale on one host (`ps:scale`). Multi-server via optional **scheduler-k3s** (and other schedulers). ([process management](https://dokku.com/docs~v0.34.9/processes/process-management/), [k3s scheduler](https://dokku.com/docs/deployment/schedulers/k3s/), [scheduler management](https://dokku.com/docs/deployment/schedulers/scheduler-management/)) |
| **vs Propraetor** | Closest *classic* CLI PaaS neighbor; still app-centric git-push, not Host IaC + thin Workload Intent. |

### Piku

| | |
| --- | --- |
| **Positioning** | “The tiniest PaaS you’ve ever seen”; Dokku-inspired `git push` deploys on small servers **without requiring Docker**. ([piku.github.io](https://piku.github.io/), [GitHub](https://github.com/piku/piku/)) |
| **Self-hosted vs managed** | Self-hosted only. |
| **How workloads are declared** | Git remote + **Procfile**; runtime installs (venv/node_modules/etc.); nginx + uwsgi. ([features](https://piku.github.io/features.html), [Procfile](https://piku.github.io/configuration/procfile.html)) |
| **Abstraction / exit** | Heroku-like workflow; nginx/uwsgi owned by Piku. No containers — exit is “ordinary processes + your Procfile,” not Docker images. |
| **Solo-operator signals** | Explicitly for tiny hardware (historical Raspberry Pi); multi-app per host; “STABLE” / feature-complete. |
| **Scaling** | Multiple apps per host; `ps:scale`-style worker scaling on that host — not a multi-server orchestrator. ([piku.github.io](https://piku.github.io/)) |
| **vs Propraetor** | Same “cheap VPS, many small apps” impulse; different runtime model (no containers/Quadlets) and no Host Stack lifecycle. |

---

## Bucket B — Self-hosted app platforms / appliance-ish

### Cloudron

| | |
| --- | --- |
| **Positioning** | “Platform that makes it easy to install, manage and secure web apps on your server”; App Store analogy (iOS/Play for servers). ([docs welcome](https://docs.cloudron.io/), [cloudron.io](https://www.cloudron.io/)) |
| **Self-hosted vs managed** | Self-hosted appliance on your VPS (Ubuntu); commercial product around packaging/updates. |
| **How workloads are declared** | Primarily **App Store / community packages** (containerized Cloudron packages), plus external links and **App Proxy**. Not a general “bring your Dockerfile as first-class Workload” product in the same sense as Coolify. ([apps docs](https://docs.cloudron.io/apps/)) |
| **Abstraction / exit** | High: packages, SSO, mail, backups, DNS/certs automated. Migration of whole Cloudron across providers is a marketed feature. Custom apps mean Cloudron packaging, not portable Quadlets. ([docs welcome](https://docs.cloudron.io/), [packages](https://docs.cloudron.io/packages/)) |
| **Solo-operator signals** | Strong for “run known apps with updates”; weaker for shipping many custom MVPs under a thin contract. |
| **Scaling** | Single-server appliance model in primary docs; not positioned as multi-cluster orchestrator. |
| **vs Propraetor** | Overlaps “reuse one server for many apps,” but **catalog/appliance** niche ≠ Propraetor’s custom Workload carrier. |

### YunoHost

| | |
| --- | --- |
| **Positioning** | Debian-based OS to “simplify server administration and therefore democratize self-hosting”; 500+ apps catalog; web admin + CLI. ([what is YunoHost](https://doc.yunohost.org/admin/what_is_yunohost/)) |
| **Self-hosted vs managed** | Self-hosted (volunteer libre project; no first-party hosting of your data). |
| **How workloads are declared** | Packaged apps via catalog; not Docker-hard-containerized by design (dedicated users, nginx, SSO). Explicitly **not** for power-user highly customized cases as primary audience. ([what is YunoHost](https://doc.yunohost.org/admin/what_is_yunohost/)) |
| **Abstraction / exit** | High OS/distribution lock-in; apps share the system. |
| **Solo-operator signals** | Excellent for personal/small-group self-host of packaged services; “just work” focus. |
| **Scaling** | Explicitly **not** designed to scale in the traditional sense (modest user counts). ([what is YunoHost](https://doc.yunohost.org/admin/what_is_yunohost/)) |
| **vs Propraetor** | Homelab/personal-server democratization; weak overlap with custom container Workloads + Host IaC. |

### CasaOS (near-miss / light overlap)

| | |
| --- | --- |
| **Positioning** | “Simple, easy-to-use, elegant open-source Personal Cloud system” around Docker; app store + custom Docker install. ([casaos.zimaspace.com](https://casaos.zimaspace.com/), [GitHub](https://github.com/IceWhaleTech/CasaOS)) |
| **Self-hosted vs managed** | Self-hosted; project messaging notes upgrade path toward **ZimaOS**. |
| **How workloads are declared** | App store + custom install from `docker run` / Appfile import. |
| **vs Propraetor** | Homelab/NAS personal cloud UI — not a solo-operator Host/Workload platform for shipping many custom projects. Included as boundary marker. |

---

## Bucket C — Deployer / bare-metal tools (native formats)

### Kamal

| | |
| --- | --- |
| **Positioning** | “Deploy web apps anywhere” with Docker; zero-downtime deploys; vision explicitly anti–commercial PaaS lock-in (Heroku/Fly/Render/K8s rentals) while keeping modern container ergonomics. ([kamal-deploy.org](https://kamal-deploy.org/), [GitHub](https://github.com/basecamp/kamal)) |
| **Self-hosted vs managed** | Tooling only — you bring servers (cloud VMs or bare metal). |
| **How workloads are declared** | App **Dockerfile** + **`config/deploy.yml`** (servers, registry, env, accessories, proxy). ([configuration overview](https://kamal-deploy.org/docs/configuration/overview/)) |
| **Abstraction / exit** | Intentionally thin vs K8s/Swarm: “basic Docker commands”; **kamal-proxy** for traffic switching. Config is Kamal-specific but small; images are ordinary Docker images. Imperative deploy model (not cluster reconciliation). ([vision](https://kamal-deploy.org/)) |
| **Solo-operator signals** | One app (or accessories) to a list of IPs; no mandatory dashboard. Fits operators who already know Linux/Docker. |
| **Scaling** | Multiple servers/roles in `deploy.yml`; external LB if multi-server. Not a shared multi-tenant Host platform. |
| **vs Propraetor** | **Closest philosophical neighbor** on lock-in and native Docker. **Does not** provision/Park Host + Durables, own a shared Edge for many Workloads, or define Workload Intent (`run`/`stop`). Complementary layer more than substitute. |

---

## Bucket D — Lightweight orchestration / container management (partial overlap)

### HashiCorp Nomad

| | |
| --- | --- |
| **Positioning** | Flexible **workload orchestrator** for containerized and legacy apps; single binary; jobspecs in HCL. ([what is Nomad](https://developer.hashicorp.com/nomad/docs/what-is-nomad), [GitHub](https://github.com/hashicorp/nomad)) |
| **Self-hosted vs managed** | Self-hosted (Enterprise available). |
| **How workloads are declared** | Nomad **jobspec** (HCL); drivers include Docker, Podman, exec, Java, QEMU. |
| **Abstraction / exit** | Owns scheduling model; pairs with Consul/Vault. Thicker than Propraetor’s Host contract; thinner than full K8s feature surface per Nomad’s own comparison. |
| **Solo-operator signals** | Docs emphasize operational simplicity vs K8s, but still a **cluster product** for orgs — not a solo PaaS. |
| **Scaling** | First-class multi-node, federation, large cluster claims. |
| **vs Propraetor** | Overlap only at “run containers on machines you own.” Propraetor explicitly avoids growing into a general-purpose orchestrator; Nomad *is* that category. |

### Portainer

| | |
| --- | --- |
| **Positioning** | Container management UI/API for Docker, Swarm, Kubernetes, Podman, ACI — hide CLI/YAML complexity. ([docs](https://docs.portainer.io/), [GitHub README](https://github.com/portainer/portainer/blob/develop/README.md)) |
| **Self-hosted vs managed** | Self-hosted CE; Business Edition licensed. |
| **How workloads are declared** | GUI over existing orchestrator resources (stacks/compose, etc.). |
| **vs Propraetor** | Management plane for containers, **not** a Host/Workload platform or PaaS substitute. Near-miss. |

---

## Bucket E — Managed PaaS Propraetor is designed *against* (contrast only)

These occupy the **alternative** side of Propraetor’s niche boundary (pay for managed DX; accept platform coupling), not the same niche.

| Product | First-party positioning (short) | Declaration model | Why contrast, not overlap |
| --- | --- | --- | --- |
| **Heroku** | PaaS on managed containers (“dynos”), buildpacks, add-ons; focus on the app not the servers. ([heroku.com/platform](https://www.heroku.com/platform/)) | Git deploy, Procfile, buildpacks | Classic lock-in / bill shape Propraetor avoids |
| **Railway** | “All-in-one intelligent cloud provider” — provision, develop, deploy. ([docs platform](https://docs.railway.com/platform), [railway.com](https://railway.com/)) | Repo / Dockerfile / images; platform networking | Managed control plane + usage billing |
| **Render** | “Deploy and scale any app… intuitive cloud infrastructure”; connect repo, Render does the rest. ([render.com](https://render.com/)) | Services + IaC YAML | Managed hosts, TLS, autoscaling |
| **Fly.io** | Fly Machines / Launch: Dockerfile or framework scan; global microVMs. ([fly docs](https://fly.io/docs/), [Machines](https://fly.io/machines), [launch](https://fly.io/docs/getting-started/launch/)) | `fly launch` / `fly.toml` + images | Managed edge + Machines; Kamal’s docs cite Fly as commercial alternative |

Self-hosted PaaS products (Coolify, Dokploy, etc.) **explicitly market themselves as alternatives to this set** — that is the shared competitive frame with Propraetor’s *economic* niche, even when product shape differs.

---

## Near-misses and non-overlaps (explicit)

| Category | Why out of scope / weak overlap |
| --- | --- |
| **Prefect.io** | Name collision only — workflow/data orchestration SaaS/OSS, unrelated Host/Workload platform. |
| **Kubernetes distributions** (k3s, k0s, RKE, EKS/GKE/DOKS…) | General-purpose orchestration; Dokku/Coolify may *use* k3s/Swarm as backends, but K8s itself is the complexity Propraetor’s graduation path tries to avoid absorbing. |
| **Full IaaS** (raw DO/AWS/Hetzner console, Terraform alone) | Building blocks Propraetor *uses*; not a Workload/Edge platform by themselves. |
| **CI/CD only** (GitHub Actions, GitLab CI without a runtime host model) | Build/deploy pipelines, not a reusable Host carrier + Edge. |
| **Panel/homelab OS** beyond CasaOS/YunoHost (e.g. TrueNAS apps, Umbrel) | Consumer/NAS appliance UX; not surveyed in depth — same boundary as CasaOS. |
| **Ansible/Capistrano alone** | Config management / classic deploy; Kamal positions itself as Capistrano-for-containers instead. |

---

## Comparison table (strong overlaps + contrast)

| Candidate | Bucket | Host ownership | Workload surface | Abstraction | Solo fit | Multi-server (documented) | Primary sources |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Coolify** | Self-hosted PaaS | Your VPS (+ optional Cloud CP) | Nixpacks / Dockerfile / Compose / Git | Medium–high (UI + Traefik) | High | Multi-server, Swarm | [coolify.io](https://coolify.io/), [docs](https://coolify.io/docs/get-started/introduction) |
| **Dokploy** | Self-hosted PaaS | Your VPS (+ optional Cloud CP) | Apps + Compose/Stack | Medium–high (UI + Traefik) | High | Multi-server, Swarm | [docs](https://docs.dokploy.com/docs/core), [self-hosted](https://dokploy.com/self-hosted-paas) |
| **CapRover** | Self-hosted PaaS | Your VPS | `captain-definition` / one-click | High (Swarm + nginx + CapRover JSON) | High | Swarm nodes | [caprover.com](https://caprover.com/), [docs](https://caprover.com/docs/get-started.html) |
| **Dokku** | Self-hosted PaaS | Your VPS | Buildpacks / Dockerfile / git | Medium (Heroku-like CLI) | Very high | Optional k3s scheduler | [dokku.com](https://dokku.com/), [docs](https://dokku.com/docs/getting-started/installation/) |
| **Piku** | Micro-PaaS | Your VPS | Procfile / git | Medium (nginx/uwsgi, no Docker) | Very high | Single host | [piku.github.io](https://piku.github.io/) |
| **Kamal** | Deployer | Your VPS (BYO) | Dockerfile + `deploy.yml` | Low–medium | High | Multi-server roles | [kamal-deploy.org](https://kamal-deploy.org/) |
| **Cloudron** | Appliance | Your VPS | App packages | High | Medium (packaged apps) | Single server (primary docs) | [docs.cloudron.io](https://docs.cloudron.io/) |
| **YunoHost** | Distro/appliance | Your machine | App catalog | High | High (personal server) | Not traditional scale | [doc.yunohost.org](https://doc.yunohost.org/admin/what_is_yunohost/) |
| **Nomad** | Orchestrator | Your cluster | Jobspec HCL | Medium (scheduler) | Low–medium | First-class clusters | [Nomad docs](https://developer.hashicorp.com/nomad/docs/what-is-nomad) |
| **Portainer** | Container UI | Existing engines | GUI over Docker/K8s | UI over engine | Medium | Multi-env agents | [docs.portainer.io](https://docs.portainer.io/) |
| **Railway / Render / Fly / Heroku** | Managed PaaS | Vendor | Platform + Dockerfile/buildpacks | High | High DX, paid | Vendor scale | See Bucket E links |

---

## Closest neighbors vs Propraetor’s distinct bet

**Same shelf in the store (economic niche):** Coolify, Dokploy, CapRover, Dokku (and lighter Piku). All say: run many apps on infrastructure you control; don’t rent Heroku/Railway/Render forever. Propraetor shares that frame in [`README.md`](../../README.md) / [`CONTEXT.md`](../../CONTEXT.md).

**Different product bet:**

- Those PaaS products optimize for **deploy DX** (UI, git push, one-click services, platform SSL/proxy). Propraetor optimizes for a **thin, portable Workload contract** on a **Stack-managed Host**, with **mechanism visible** (Edge, Quadlets, Terraform) and **graduation** when a Workload outgrows the shared Host.
- **Kamal** matches Propraetor’s lock-in skepticism and Docker-native posture most closely, but stops at **per-app deploy tooling**. Propraetor additionally owns Environment-scoped Host lifecycle (Apply/Park/Teardown), Durables (Reserved IP, Host Volume), and a shared Edge/Workload Intent model.
- **Cloudron / YunoHost** overlap “one box, many apps” but center **packaged apps / personal servers**, not custom MVP Workloads under a thin Manifest.
- **Nomad / Portainer / K8s** are infrastructure engines or UIs — useful underneath or after graduation, not the same solo Host platform.

**No primary-sourced twin** was found for Propraetor’s combination of: (1) provider Stack IaC for Host+Durables, (2) Park as first-class cost operation, (3) thin Manifest Intent, (4) native Workload formats, (5) deliberate non-growth into general orchestration.

---

## Gaps / not verified from primary sources

- **Park/Durables-equivalent lifecycle** (destroy compute, keep reserved IP + volume, reattach): not documented as a named product feature in any surveyed candidate; absence is inferred from missing claims, not from exhaustive feature matrices.
- **Coolify / Dokploy “stop using us, keep apps” exit**: marketing/docs assert portability; exact leftover Traefik labels, networks, and volume layouts after uninstall were **not** audited in a live teardown for this note.
- **CapRover post-removal behavior**: homepage claims apps keep working; no deep primary runbook for clean CapRover uninstall was followed end-to-end here.
- **Portainer** official intro page timed out once during research; positioning taken from docs home snippets + GitHub README.
- **CasaOS** `casaos.io` redirected; positioning taken from [casaos.zimaspace.com](https://casaos.zimaspace.com/) and GitHub.
- **EasyPanel, Porter, Elestio, Sealos, and similar** appeared in secondary discovery lists but were **not** fully primary-sourced for this note (avoid laundry list).
- **Propraetor (this repo) runtime details** (Quadlets, nginx Edge, DO Stack) are from in-repo docs, not third-party pages — used only to define the niche for comparison.
