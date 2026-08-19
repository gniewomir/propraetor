# Propraetor

Propraetor owns reusable Hosts and a thin Workload contract so a solo operator can ship many small projects, experiments, and MVPs without repeating platform work, paying for managed infrastructure too early, or becoming dependent on a PaaS that is costly to leave. It removes unproductive friction (platform TLS, repeated provisioning) and keeps productive friction (declaring how containers run). Host capacity changes should remain routine and low-disruption; scale vertically while the shared Host remains sufficient, then graduate a Workload to dedicated infrastructure.

## Language

**Propraetor**:
The name of this project: infrastructure-as-code for the platform other projects run on (Hosts, networks, environments) — without deciding what those projects are. From Latin *propraetor*: delegated provincial command on the same Roman magistracy ladder as *praefectus* / *legatus* — an appointed authority placed over a defined sphere under delegated power, not ownership of the work’s purpose.
_Avoid_: Infra, platform repo, DevOps project (when you mean this project)

**Stack**:
A Terraform root module that owns a cohesive slice of infrastructure for one provider or concern. Today the only stack is DigitalOcean (past Bootstrap: it manages Hosts and related network resources). One Stack definition is Applied separately per Environment.
_Avoid_: Project, workspace (Terraform State slices are an implementation detail — see Environment); Environment (when you mean the module itself rather than an instance)

**Environment**:
A namespaced instance of a Stack under one provider account: its own State and its own account-unique cloud names (including Cloud Project, Host, Host Volume, Domain, tags, Firewall). Identified by an open-ended operator-chosen slug (e.g. `test`, `prod`, `dev`, `staging` — no fixed enum). When no Environment is explicitly selected, the operator is on the **test** Environment. In operator tooling, `test` and `default` refer to that same Environment (`default` is the only alias). Propraetor operator CLI is safe by default: every operator entrypoint accepts an Environment parameter and affects **test** unless another Environment is explicitly specified. A `prod` Environment is optional — created only when needed. Distinct from the provider Cloud Project’s metadata `environment` field (Production / Staging / …), which is billing/UI labeling only.
_Avoid_: Workspace, stage, stack instance, Terraform workspace (when you mean this concept); environment variable / process environment (shell); Cloud Project `environment` field

**Cloud Project**:
A provider-side folder that groups billable resources for UI and billing. Distinct from Propraetor, Stack, and Environment. Each Environment gets its own Cloud Project (namespaced by Environment slug). Resources that cannot be assigned (Firewall, tags) stay Stack-managed only.
_Avoid_: Project (bare), DO project (when speaking in domain language)

**Bootstrap**:
The initial content of a Stack: provider configuration, version pins, authentication wiring, and state backend — deliberately without managed cloud resources. Bootstrap for the DigitalOcean Stack is complete once Hosts (and their network companions) are managed in State.
_Avoid_: Scaffold, skeleton, hello-world

**State**:
The Terraform record of what a Stack currently manages. For Bootstrap, State is local to the operator's machine.
_Avoid_: Backend, tfstate (implementation jargon for the concept itself); Persist / `persist/` (Host Volume owner bytes)

**Provider Credential**:
A secret used to authenticate to a cloud provider API. Supplied via the operator's environment (never committed); for DigitalOcean that is the API token in `DIGITALOCEAN_TOKEN`. Baseline may come from the repo-root gitignored `.env` when present; a non-empty process-environment value overrides the file.
_Avoid_: Credential (bare), Key, secret, password (when you mean this); Operator Configuration; Environment Configuration

**Operator Configuration**:
Operator-machine inputs Propraetor tooling requires (paths and similar), distinct from provider API auth and from Environment Configuration. Today: the matched SSH public- and private-key paths used for Host login and Initial Host Provisioning; the ACME contact email used when an Environment has committed ACME configuration; and an optional path to the **Environments root** (directory of `<slug>/` Environment trees) that relocates Environment SoT away from the repository default when set. Baseline may come from the same repo-root gitignored `.env` as Provider Credential; a non-empty process-environment value overrides the file. Path values are absolute or `~/…` only. The ACME contact is optional at load and required only when staging ACME for an Environment that has `acme.json`. The Environments root is optional at load; when set it fully replaces the repo Environments root for tooling (no fallback), and Acceptance / Lifecycle refuse to run with it set. Committed `.env.example` documents the allowlist; neither bag is Environment Configuration.
_Avoid_: Provider Credential, Credential, Environment Configuration, SSH identity / identity (when you mean Adopt or resource identity); SSH key (when you mean a provider-account registry resource); ACME configuration (when you mean the contact email alone); Environment (when you mean the on-disk tree root)

**Environment Configuration**:
The Environment-scoped bag of non-committed key/value pairs the operator supplies for Workload Setup to materialize into one Platform User–local EnvironmentFile per Workload at `~/.config/platform/workloads/<basename>/environment`, wired onto that Workload’s `systemd/*.container` install units via a Setup-owned Quadlet drop-in (`EnvironmentFile=` — not unit-text substitution, not onto the Host Volume Workload trees). Baseline from gitignored `environments/<slug>/.env` when present; optional `.env.override` overlays on key collision; current shell overriding any key from either file (precedence: shell > `.env.override` > `.env`); a Workload’s **Binding** remaps bag keys onto names from **Requires** `environment` (surplus bag keys ignored for that Workload); missing remapped keys fail closed in Workload Setup; a non-empty Requires environment map with no `systemd/*.container` also fails closed. For `Source` `internal`, operator Setup full-fulfills Binding against Environment `requires.json` (it is the Artifact) and applies the containers gate on the Environment tree. For zip Source, the Environment tree is Manifest + Binding (plus the `.zip` when obtain is a path) — Environment `provides.json` / `requires.json` fail closed (operator Mirror and Setup, and Host materialize before zip obtain); operator remap is Binding + bag only; Host full-fulfills Binding against Artifact Requires and applies the containers gate after materialize. Re-Setup rewrites the file from current sources (the rotation path). Components do not consume this Workload bag. Key names are operator-owned — Setup does not reserve or reject Workload bag names — but prefer not to use the `PLATFORM_*` prefix, **Provider Credential** names (`DIGITALOCEAN_TOKEN` today; future tokens in the same Provider Credential role), **Database admin credentials** (`ROOT_DB_USER`, `ROOT_DB_PASSWORD`), **Cache admin credentials** (`ROOT_CACHE_USER`, `ROOT_CACHE_PASSWORD`), or **Identity admin credentials** (`ROOT_IDENTITY_API_KEY`, `ROOT_IDENTITY_ENCRYPTION_KEY`, `ROOT_IDENTITY_ADMIN_EMAIL`) as Binding remaps into Workloads; those admin credential names are reserved and must not be injected into Workloads (fail closed if remapped). The same `.env` / `.env.override` files may also hold Database, Cache, or Identity admin credentials — they are not this bag. Distinct from Stack/Terraform configuration under that Environment directory, from the process environment as a concept, from **Provider Credential**, from **Operator Configuration**, from **Database admin credentials**, from **Cache admin credentials**, and from **Identity admin credentials**.
_Avoid_: Environment (the Propraetor instance); Stack configuration / Terraform config (when you mean files under `environments/<slug>/` other than this bag); environment / env / environment variable (process/shell, when you mean this bag); Operator Configuration; Provider Credential; Credential; secrets (when you mean the whole bag); dotenv / `.env` (when you mean the bag, not the file); placeholder substitution (not the injection path); Database admin credentials; Cache admin credentials; Identity admin credentials; ROOT_DB_USER / ROOT_DB_PASSWORD / ROOT_CACHE_USER / ROOT_CACHE_PASSWORD / ROOT_IDENTITY_API_KEY / ROOT_IDENTITY_ENCRYPTION_KEY / ROOT_IDENTITY_ADMIN_EMAIL (when you mean those reserved keys); Manifest environment list (retired)

**Database admin credentials**:
Environment-scoped operator-supplied `ROOT_DB_USER` and `ROOT_DB_PASSWORD` staged onto the Host for the **Database** Component’s SCRAM admin role (Component Setup and operator `database.sh`). Baseline from the same gitignored `environments/<slug>/.env` when present, optional `.env.override` overlay, current shell overriding (same precedence as Environment Configuration); mandatory for Database Setup. Not **Environment Configuration** — never remapped by Binding into a Workload EnvironmentFile. Distinct from Operator Configuration and from Workload client-cert bindings.
_Avoid_: Environment Configuration; Operator Configuration; database password (when you mean Workload mTLS — Workloads have none); ROOT credentials (bare)

**Cache admin credentials**:
Environment-scoped operator-supplied `ROOT_CACHE_USER` and `ROOT_CACHE_PASSWORD` staged onto the Host for the **Cache** Component’s admin ACL role (Component Setup and operator `cache.sh`). Same baseline / overlay / shell precedence as Environment Configuration; mandatory for Cache Setup. Not **Environment Configuration** — never remapped by Binding into a Workload EnvironmentFile. Distinct from Operator Configuration and from Workload client-cert bindings.
_Avoid_: Environment Configuration; Operator Configuration; Valkey password / Redis password (when you mean Workload mTLS — Workloads have none); ROOT credentials (bare)

**Host**:
A virtual machine managed by a Stack. The first Host in this Stack is a public web host (HTTP/HTTPS plus SSH).
_Avoid_: Droplet, instance, VM, box, server (when you mean this compute resource)

**Host Image**:
The provider distribution image the Stack pins for a Host (today: Ubuntu 26.04 x64). Changing it recreates the Host.
_Avoid_: Droplet image, OS slug, AMI (when you mean this concept)

**Initial Host Provisioning**:
One-shot Host setup at Host create (provider user-data / cloud-init) that produces **Substrate** (engine, Platform User, SSH listen port, port floor, Host Volume mount); installs the Operator Configuration public key for **root** Host login only — not onto the Platform User. Does not run Fabric Setup, Component Setup, or install Workloads. Not ongoing Host management and not Stack Bootstrap.
_Avoid_: User Data, cloud-init, userdata (when you mean this concept); provisioning (bare — ambiguous with Stack apply); Substrate, Fabric (when you mean this delivery); Carrier; provider account SSH key registry (not how Host login is granted)

**Initial Host Provisioning Done** (alias **IHP Done**):
Host-local gate that the IHP contract holds on a public Host — that the Host is **Substrate** (IHP finished, SSH port cutover reboot completed, port floor 80, Platform User present, Host Volume mounted). Asserts Substrate readiness for Fabric Setup, not that Fabric is present (Service Network is Fabric and out of this gate) and not that Components or Workloads are installed. Names what completed; Substrate names the resulting Host condition. Used by Deploy / ensure-fabric / ensure-components, and Acceptance Tests before asserting finer capability slices. Delivery mechanics (cloud-init) stay inside the gate’s implementation.
_Avoid_: Fabric ready, Substrate ready (prefer IHP Done for the gate), Carrier ready, cloud-init ready, Component Setup ready, Component Setup Done, provisioned (bare), ready (bare)

**Substrate**:
The Host condition after IHP Done: everything required to run Fabric Setup is present (today: container engine, Platform User, SSH listen port, port floor, Host Volume mount, and **Platform journal** readiness), while Fabric itself may still be incomplete. A Host condition — not a Setup kind and not a peer of Fabric, Component, or Workload.
_Avoid_: Carrier, IHP Done (when you mean the condition rather than the gate), Fabric, provisioned (bare), ready (bare)

**Host diagnostics**:
An operator pull of Host-local diagnostic artifacts for an Environment (named bundles of files and small command snapshots) for local inspection. Not IHP Done, not an Acceptance Test, not ongoing Host management, and not the **Platform journal** (runtime unit/container streams).
_Avoid_: logs (bare), cloud-init logs (when you mean this operator capability); Platform journal (when you mean this pull); debug dump, support bundle (when you mean this Propraetor operation)

**Platform journal**:
The Platform User’s systemd journal as the sole destination for Propraetor-owned unit and container diagnostic streams on the Host (Quadlet-generated and authored `systemd/` units). Part of **Substrate**. Not Host diagnostics, not IHP cloud-init files, and not application log files on the Host Volume. Access/request streams are not required by default.
_Avoid_: logs (bare), container logs (bare), journald (when you mean this Propraetor contract); Host diagnostics; access logs (when you mean the default-off request stream)

**Reserved IP**:
A stable public IPv4 address owned by the Stack and assigned to a Host. It survives Host rebuilds and Park; Teardown removes it with the rest of the Stack. The Host's own public IP does not survive rebuilds.
_Avoid_: Floating IP, static IP, elastic IP (when you mean this address resource)

**Domain**:
The Stack-managed DNS Durable for an Environment: the provider zone and the Stack-authored records under it. A records to the Environment’s Reserved IP are required for each declared name (apex or subdomain); a Domain may carry more Stack-authored records over time. Certificate material for those names is Domain-scoped — a Workload may use a Domain’s names via Routes; it does not own the Domain or its certificates. An Environment may have zero or more Domains. Park keeps it; Apply reattaches it; Teardown removes it; assigned to the Environment’s Cloud Project. Not Workload ownership of names.
_Avoid_: DNS zone, zone file, domain name (bare), subdomain (when you mean this Durable or part of it); Workload-owned certificate; Manifest hostname claim

**Host Volume**:
A Stack-owned block volume attached to a public Host for data that must survive Host rebuilds and Park (Teardown removes it with the rest of the Stack). Mandatory on public Hosts (one per Host for now). The **mounted** filesystem at contract path **`/host-volume`** is part of **Substrate** (established by IHP; required before Fabric Setup and before Components/Workloads use the volume). The mount root stays root-owned; everything under it is Platform User–owned so rootless Quadlets and Workload Setup can use it. Under the mount (no `internals/` prefix, no top-level `data/` parents): **`fabric/`**, **`components/<name>/`**, Mirrored **`workloads/<basename>/`**, and **`host-scripts/`** (Host-executable scripts and their `lib/`). Each Workload and Component owner tree may hold optional nested **Persist** (`persist/`) for bytes that must survive Mirror/ensure replace of the rest of that owner tree; other owner paths are replaceable SoT. Operator-machine shared helpers live in the repo under `internals/lib/` and are not a Host Volume tree — repo `internals/` is not the Host Volume layout. Platform User unit install lives under the Platform User’s home (symlink farm into Quadlet discovery), not as the authored SoT location. One Host Volume per Host — not a separate volume resource per Workload.
_Avoid_: Volume (bare), disk, block storage, persistent volume, DO volume (when you mean this Propraetor resource); Fabric, Substrate (when you mean only the Stack block device, not the mount); `internals/` / top-level `data/` / `components_data/` (retired Host Volume layout); `/var/lib/host-volume` (retired mount contract)

**Persist**:
Optional `{owner}/persist/` under a Host Volume Workload or Component owner tree for Host-persisted bytes that Mirror/ensure must not replace. Artifact and Provides must not ship `persist` / `persist/…` (fail closed). When projection finds no `persist/`, Setup creates an empty one for Workloads and Components. Quadlet-relative binds from `systemd/` use `../persist/…`. Not Stack **State**, not a Durable cloud resource.
_Avoid_: State, Durable, durable/, data/ (retired top-level Host Volume parent), workload state (ambiguous)

**Firewall**:
A provider-enforced network filter attached to Hosts. Inbound default deny (only SSH, HTTP, HTTPS, and ICMP allowed); outbound unrestricted. The Stack does not manage a host-level firewall. Attachment is by Role Tag, not by Host ID alone.
_Avoid_: Security group, ufw, iptables, cloud firewall (product name when you mean this concept)

**Propraetor Tag**:
A provider tag that marks taggable resources as belonging to Propraetor (name derived per Environment, e.g. test: `propraetor-test`). Applied to every Propraetor Host. Not all Stack resources are taggable (Firewall and Reserved IP are not).
_Avoid_: Office Tag, Shared tag, propraetor tag (when you mean this concept); Role Tag

**Role Tag**:
A provider tag that selects Hosts for a policy such as a Firewall (public web for test: `propraetor-test-public-web`). Orthogonal to the Propraetor Tag; a Host may carry both.
_Avoid_: Firewall tag (ambiguous — the Firewall targets the Role Tag; it is not itself tagged)

**Acceptance Test**:
An executable check that the live Stack’s **Deployed** Host matches the intended contract (observable outcomes only — not Terraform internals). Suite baseline between cases is **Deployed** (runner re-converges via **Deploy**). Non-destructive to Stack lifecycle: must not Park or Teardown. Defaults to the **test** Environment (ADR-0019); non-**test** use is diagnostic and confirm-gated — Environment SoT stays at committed truth (ADR-0042).
_Avoid_: Verify script, observability check, smoke test, integration test, Lifecycle Test, Unit Test (when you mean this concept)

**Lifecycle Test**:
An executable check of Stack lifecycle operations that deliberately remove or restore Stack presence (Park, Apply-after-Park, Teardown). Opt-in; **test Environment only**; suite baseline between cases is Stack absent (post-**Teardown**); suite-start confirm-gated (ADR-0042). Distinct from Acceptance Tests and Unit Tests (ADR-0042).
_Avoid_: Acceptance Test, Unit Test, destroy test, integration test (when you mean this concept)

**Unit Test**:
An executable check of Propraetor library or helper behavior with no Applied Stack and no lasting side effects outside the test’s own temporary workspace. If the unit or test needs lasting side effects, it is not a Unit Test (Acceptance or redesign) (ADR-0042).
_Avoid_: unit (bare), shell test, lib test, integration test, Acceptance Test, Lifecycle Test (when you mean this concept)

**Apply**:
The operation that converges a Stack to Applied from Applied, Parked, or a supported partially failed lifecycle operation. Repeating Apply is the normal recovery path and ends with an empty plan; may Adopt allowlisted facts as part of its normal convergence. External drift, unmanaged collisions, Adopt ambiguity, and provider/account hard failures remain explicit blockers.
_Avoid_: up, provision, terraform apply (when you mean this operation)

**Adopt**:
The binding of an already-existing provider fact into State under the Environment’s known Stack-owned identity. Adopt starts with exact-match preflight; binding may complete there or during the ensuing normal lifecycle convergence when an already-correct relationship cannot be bound earlier. Apply may Adopt allowlisted Durables and known Recreatable relationships; Park and Teardown may Adopt allowlisted Durables and Durable relationships only. None is a separate operator command. Scope is identity-stable Durables (Domain, Host Volume, Cloud Project, and their Durable memberships) and — for Apply only — known Recreatable relationships whose endpoints are already known. Ambiguity, wrong endpoint, identity conflict, or a binding that would move or rewrite the provider fact fails closed. Not discovery of an unbound Host by name, and not an orphan Reserved IP address (no Environment key without State).
_Avoid_: import, terraform import, State surgery, auto-import (when you mean this concept)

**Applied**:
The stable Stack condition in which every configured Durable and Recreatable is present and converged.
_Avoid_: running, up, active

**Durable**:
A Stack-managed resource or relationship that Park preserves and Apply keeps converged. Today this includes the Reserved IP, Host Volume, Domain, Cloud Project, and the relationships that keep those resources assigned while Parked.
_Avoid_: persistent resource, stateful resource (when you mean this Park/Apply set)

**Recreatable**:
A Stack-managed resource or relationship that Park removes and Apply recreates without preserving its identity or data. Today this includes the Host and its Applied-only companions and relationships.
_Avoid_: non-durable, ephemeral resource, disposable resource

**Additive Stack Change**:
A configuration change that adds resource instances or relationships while leaving every existing managed identity and desired attribute unchanged.
_Avoid_: non-destructive change, additive update (bare)

**Park**:
The operation that converges a Stack to Parked from Applied, Parked, or a supported partially failed lifecycle operation. May Adopt allowlisted Durables as part of its normal convergence. A cost convenience for development and other non-production Environments; Durables continue to bill while Parked.
_Avoid_: soft destroy, soft teardown, down, halt, suspend, Destroy (ambiguous — say Park or Teardown)

**Parked**:
The stable Stack condition in which every configured Durable is present and converged and every Recreatable is absent.
_Avoid_: stopped, down, inactive

**Teardown**:
Permanently remove every resource the Stack currently manages, including Durables, leaving State empty. May Adopt allowlisted Durables first so Environment-keyed orphans are included in the wipe. Stack configuration stays in the repository and can be Applied again. Explicit full wipe when Durable billing should stop — not the idle path for non-production (that is Park).
_Avoid_: Destroy, wipe, delete resources, terraform destroy (when you mean this full removal); Purge (retired Workload Intent-destroy); Orphan Reap (Workload Host cleanup, not Stack wipe)

**Fabric**:
The post-Substrate Host-local layer Components and Workloads require before they can run — workable-state members that neither gather Declarations nor express operator Intent. Today: the Service Network. Distinct from **Substrate** (engine, Platform User, ports, Host Volume mount — established by IHP) and from Components. Applied by **Fabric Setup**.
_Avoid_: Substrate, IHP, IHP Done, Component, Workload, prerequisite (bare), carrier, Host Volume mount (Substrate, not Fabric)

**Fabric Setup**:
The idempotent, declarative Host-side application of Fabric. Requires **Substrate**; after success, Fabric outcomes are in the correct state; re-runs with no change are a noop. Today applies the Service Network. Runs on the Host only; does not gather Workload declarations, does not perform Component fulfillment, and does not install Workloads. Distinct from Component Setup, Workload Setup, Mirror, and Initial Host Provisioning.
_Avoid_: Setup (bare), Component Setup, Workload Setup, Mirror, IHP, Substrate Setup, ensure-components (when you mean this Fabric action)

**Mirror**:
The idempotent materialization of each Environment **Workload** onto Host Volume `workloads/<basename>/`, **regardless of Source** — upsert the Environment tree (Manifest, Binding, and any inline Artifact bytes), resolve Manifest **Source**, and apply **Provides** `directories` onto that Host tree (fail closed if reserved Artifact/Propraetor files already collide at the destination, including reserved **Persist**). Preserves existing Host **Persist** under that owner. Zip Source Environment trees must not contain `provides.json` or `requires.json` (operator fail-early; Host materialize fail-closed before zip obtain). Discovers Workloads as every immediate non-hidden directory under the Environment (directory basename = identity; ADR-0033). Does not apply Intent, fulfill Component interior, ship Fabric/Component source, or materialize Environment Configuration. Does not validate Manifest beyond what Source resolution requires; consumers (Workload Setup, Component Setup gather) stay selective. Updates trees that already exist on the Host, adds missing ones, and **leaves orphans alone** (Host basenames not in the Environment). Orphan removal is **Orphan Reap**.
_Avoid_: HSoT, Host SoT, sync (bare), rsync, Workload Setup, Fabric, Component Setup, Deploy, Orphan Reap (when you mean only this materialize); opaque bag only (retired — Mirror also resolves Source); Purge (retired)

**Deploy**:
The operator Host operation that takes a **Substrate** Host to **Deployed**. Ladder: **Fabric Setup** → **Mirror** → **Orphan Reap** → **Component Setup** (`pre-workloads`) → **Workload Setup** (every Environment Workload) → **Component Setup** (`post-workloads`).
_Avoid_: Apply (Stack), ensure (bare), provision, ship

**Deployed**:
The Host condition after **Deploy**: Fabric holds; Environment orphans have been reaped; both Component Setup slots have run and Components are in the correct state for that Environment, including Declaration fulfillment from Mirrored Workload SoT; every Environment Workload has had Workload Setup applied (Intent honored — not “all processes started”).
_Avoid_: started, live, up, running (when you mean this Host condition); Substrate, Parked

**Component**:
A platform-provided Host capability that owns a shared resource and fulfills **Declarations** from agreed SoT (Workload trees and/or Environment config such as Domain assignment). Gather → ensure → publish is Component-owned; Workload Setup does not perform Component fulfillment. Components do not have Workload Intent (`run`/`stop`); presence and correctness are Component Setup’s job. Distinct from Fabric and from Workloads. Today: the Edge, the Database, the Cache, and **Identity**.
_Avoid_: Package, unit, service, module, Fabric, Substrate, Workload, provider, Intent (when you mean this Propraetor kind)

**Declaration**:
A statement of what a Workload **Provides** or **Requires**, or an Environment-authored claim (today: Domain assignment feeding Edge; Identity issuer hostname via `identity.json` on that want-list). Binding may resolve Workload Declarations against Environment Domains and Environment Configuration; Components may gather the subset they fulfill (bound Routes → Edge; Requires `database` → Database; Requires `cache` → Cache; Requires `identity` with Provides/Requires `permissions` → Identity; Domain assignment → Edge). Distinct from Workload Intent, from **Binding** (Propraetor-internal resolution), and from fulfillment artifacts inside Component interior.
_Avoid_: Claim, request, need, requirement, dependency, attachment, binding (bare — use **Binding** for the Propraetor file), spec, Manifest (when you mean this umbrella); Route (when you mean only that kind); Provides / Requires (when you mean only one side)

**Component Setup**:
The idempotent, declarative Host-side application of one Component’s correct state, including gathering Declarations and fulfilling them into that Component’s interior under Host Volume `components/<name>/` (including **Persist** when needed) when that slot requires it. A Component supplies two Host Setup scripts — `pre-workloads` and `post-workloads` — selected by when Setup runs relative to Workload Setup on the Deploy ladder (and by the same choice when Setup is composed outside Deploy). What each script does is Component-owned; Deploy always runs both slots; making Components correct outside Deploy means running both in that order — there is no combined single-shot mode. Re-running after Workload SoT or Environment Declaration inputs change is how fulfillment refreshes; when inputs and interior already match, Setup is a noop. Reads that Component’s source tree from Host Volume `components/<name>/` (and may source shared Host-local helpers from `host-scripts/lib/`); runs on the Host only; does not discover the Stack, SSH, or copy itself onto the Host. Used for first bring-up after Fabric holds and Mirror has placed Workload SoT, and for later re-runs without Host recreation. Installs authored units from that Component’s `systemd/` bag (Quadlet sources and native units) into the Platform User unit search path.
_Avoid_: Setup (bare), install, deploy, provision, Workload Setup, Fabric Setup (when you mean this Component action); full Component Setup, epilogue, Edge converge (when you mean a Component Setup slot)

**Workload Setup**:
The idempotent, declarative Host-side application of one Workload’s Intent from its Manifest: ensure that Workload’s Host Volume tree matches what **Mirror** would materialize for its Source (so singular Setup does not invent a second materialize path); then sync operator-authored units and apply them per Intent; materialize **Environment Configuration** per **Binding** remap of **Requires** `environment` (operator Binding + bag; Host full-fulfill against Artifact Requires after materialize — zip Environment trees have no `requires.json`). Bound Route Declarations are fulfilled into Edge-owned storage by Edge Component Setup — Workload Setup does not write Edge interior, reload the front door, or invoke Component Setup. After projection, the Workload’s `systemd/` bag must contain at least one unit file (Quadlet source or native unit); zero Provides routes is valid. Basename ownership is global across the Platform User unit search path; wrong-folder authorship and missing remapped Environment Configuration keys fail closed. Does not generate Route or unit content from the Manifest; does not write Domain fronts or perform Component fulfillment. Distinct from Component Setup, Mirror (materialize without Intent), and **Orphan Reap**. Under **Deploy**, Mirror runs first so Setup’s materialize is a noop when trees already match; Deploy’s `post-workloads` Component Setup refreshes Edge after Workloads — outside Deploy the caller composes Component Setup `post-workloads` when Declarations may have changed.
_Avoid_: Setup (bare), Component Setup, Mirror (when you mean Intent apply), install, Deploy (when you mean only one Workload), Orphan Reap (when you mean this Workload action); Purge (retired)

**Edge**:
The mandatory public HTTP/HTTPS front door on a public Host. A Propraetor Component (not Fabric; mandatory today as a product bit, not because Components are always mandatory). Sole publisher of Host ports 80/443; terminates TLS using Domain-scoped certificates; owns on-demand ACME as the issuance mechanism. Owns **Forwarded client identity** on every request it proxies to a Workload. For each want-list FQDN it publishes a Domain front; gathers Intent-**run** bound Route **Declarations** (Provides routes attached by Binding) and fulfills them into Edge-owned storage included by Domain fronts — refresh by Component Setup `post-workloads` after Workload Setup or **Orphan Reap** (noop when unchanged); `pre-workloads` keeps a usable front door for Domain/ACME concerns without loading Workload Routes that still depend on Workload Setup. When an FQDN is claimed by **Identity** (`identity.json`), that Domain front carries an Edge-owned proxy block to the Identity Service Network dial name instead of Workload Routes; Edge `post-workloads` fails closed if any Workload Binding attaches Routes to the Identity-claimed FQDN. ACME’s want-list is the explicit FQDN set from the Environment’s Domain assignment (apex + `names`) — an Environment-authored Declaration input. ACME’s Let’s Encrypt directory comes from the Environment’s committed ACME configuration (`acme.json`) when present; contact email comes from Operator Configuration when that file is present; absent file means staging with Host-derived contact. On :80, only ACME challenges and HTTPS redirects — never Workload cleartext. A missing Workload upstream after Routes are loaded is a request-time failure (Edge stays up), not a Setup failure.
_Avoid_: Reverse proxy, ingress, gateway, nginx (when you mean this Propraetor role — nginx is today’s implementation); Fabric

**Forwarded client identity**:
The Edge-owned set of HTTP hop headers that describe the public client for a request Edge proxies to a Workload — always overwritten from the public TCP peer and request scheme/host, never left as client-supplied values. Includes the conventional `X-Forwarded-*` / `X-Real-IP` / upstream `Host` headers and the RFC 7239 `Forwarded` header as one contract. Soft use by Workloads (logging, redirects, URL generation); not a claim that the same headers are authentic on Service Network traffic that never passed through Edge, and not hop authentication of Edge to the Workload.
_Avoid_: trusted proxy headers, X-Forwarded-For (bare), forwarded headers (bare), Forwarded (bare RFC name when you mean this whole contract), client IP (bare)

**Database**:
The shared PostgreSQL Component on a public Host (mandatory product bit; may idle with zero claimants). Service Network dial name `database` (Workload basename `database` is rejected). Fulfills Intent-**run** **Requires** `database: true` Declarations into per-basename role, database, and TLS client-cert binding; publishes that binding for the Workload’s containers; unpublishes when Intent is not **run**; drops role, database, and client material on **Orphan Reap**. Workloads authenticate with client certificates (passwordless); admin SCRAM uses **Database admin credentials**. Distinct from a Workload-owned in-pod database.
_Avoid_: Postgres (bare), DB (bare), shared database (when you mean this Component); Environment Configuration; Edge; Manifest database (retired)

**Cache**:
The shared in-memory key-value Component on a public Host (mandatory product bit; may idle with zero claimants). Engine is Valkey. Service Network dial name `cache` (Workload basename `cache` is rejected). Fulfills Intent-**run** **Requires** `cache: true` Declarations into a per-basename ACL user, TLS client-cert binding, and key prefix `basename:`; publishes that binding for the Workload’s containers; on Intent not **run**, unpublishes and disables the ACL user; on **Orphan Reap**, deletes the user, client material, and best-effort keys under that prefix. Workloads authenticate with client certificates (passwordless); keyspace is ephemeral (survives neither Component restart nor Host rebuild as durable SoT) and may be evicted under global memory pressure; admin ACL uses **Cache admin credentials**. Distinct from a Workload-owned in-pod Valkey/Redis-compatible process.
_Avoid_: Redis (when you mean this Component), Valkey (bare — prefer **Cache** for the Component; Valkey names the engine), shared cache (bare), Environment Configuration; Edge; Manifest cache

**Identity**:
The mandatory public Identity Provider Component on a public Host (idles with zero claimants; peer of Edge, Database, Cache). Engine is Pocket ID. Service Network dial name `identity` (Workload basename `identity` is rejected). Issuer hostname declared in committed `environments/<slug>/identity.json` (one want-list FQDN; missing file = no issuer, Identity idles); Edge owns the Domain front for that FQDN with an Edge-owned proxy block to the Identity dial name — not a Workload Route; Edge fails closed if any Workload Binding attaches Routes to the Identity-claimed FQDN. Gathers **Requires** `identity: true` with a permission catalog (**Provides** `permissions`, Environment-scoped) and/or an OIDC client (**Requires** `permissions` plus **Provides** `oidc_callback`). Fulfills catalog, client registration, and client grants; publishes issuer, JWKS URL, and environment-scoped audience/resource `propreator:${env-slug}` to API Workloads, and issuer, client id (basename), callback URLs, resource, and scopes to a client Workload. Intent **stop** unpublishes that binding and **leaves** Identity interior records; omitting the Declaration or **Orphan Reap** drops them. Distinct from **Edge** (Edge is not the token verifier) and from the **Service Network** (no tokens between co-tenant Workloads). Propraetor owns gathered objects (catalogs, clients, grants) by known Workload identity — full-replace on Deploy; operator owns users, passkeys, groups, and UI-created objects with unrecognized IDs; UI edits to gathered objects are **Escape Hatch**. Changing the issuer hostname is a WebAuthn RP ID change (every passkey breaks) — treat as effectively immutable.
_Avoid_: IdP (expand **Identity Provider** on first use), OIDC server / SSO / Auth (when you mean this Component), Edge JWT, Forwarded client identity (Edge hop headers), Pocket ID (when you mean the Component — Pocket ID names the engine)
_Pocket ID admin API facts_: `docs/research/pocket-id-apis-admin.md` (resource servers / permissions), `docs/research/pocket-id-oidc-clients-admin.md` (OIDC client CRUD)

**Identity admin credentials**:
Environment-scoped operator-supplied `ROOT_IDENTITY_API_KEY`, `ROOT_IDENTITY_ENCRYPTION_KEY`, and `ROOT_IDENTITY_ADMIN_EMAIL` staged onto the Host for the **Identity** Component (Component Setup and admin API access). Same baseline / overlay / shell precedence as Environment Configuration; mandatory for Identity Setup. `ROOT_IDENTITY_API_KEY` is staged as Pocket ID `STATIC_API_KEY` (admin API auth). `ROOT_IDENTITY_ENCRYPTION_KEY` is staged as Pocket ID's encryption key (lost key = unreadable SQLite). `ROOT_IDENTITY_ADMIN_EMAIL` is consumed only on first deploy (Setup creates the admin user and prints a one-time login URL). Not **Environment Configuration** — never remapped by Binding into a Workload EnvironmentFile. Distinct from Operator Configuration and from Workload bindings.
_Avoid_: Environment Configuration; Operator Configuration; ROOT credentials (bare); Database admin credentials; Cache admin credentials

**ACME configuration**:
Committed Environment file declaring Edge ACME’s Let’s Encrypt directory (`production` or `staging`) only. Distinct from Domain assignment (which FQDNs), from Environment Configuration (Workload bag), and from the ACME contact email (Operator Configuration). Missing file is valid — staging and Host-derived contact; present file requires Operator Configuration contact email at ACME staging.
_Avoid_: Environment Configuration, domains.json, Credential, Operator Configuration (when you mean the directory declaration)

**Identity configuration**:
Committed Environment file `environments/<slug>/identity.json` declaring which single Domain want-list FQDN the Identity Component binds to as its issuer hostname. Required for every Environment — missing file fails closed at Deploy. Must contain exactly one want-list FQDN (no placeholder state); fail closed if the FQDN is not on the want-list. `ensure-components` stages it onto the Host alongside the ACME want-list and admin credentials. Peer of `domains.json` and `acme.json` — an Environment-authored Declaration input. Changing the issuer FQDN is a WebAuthn RP ID change (every passkey breaks).
_Avoid_: Environment Configuration, domains.json, acme.json (when you mean this file); Workload Binding (when you mean this Environment Declaration)

**Domain front**:
Edge-owned per-FQDN drop-in for one want-list name: the HTTPS `server` that terminates TLS for that Domain name and includes matching bound Workload Routes (or, when claimed by Identity, an Edge-owned proxy block to the Identity dial name instead of Workload Routes). Publishes Edge baseline `/healthcheck` and the per-name `:80`→HTTPS redirect without a Workload Route. Shape SoT is Edge Component `domain-template.conf`; Edge Setup renders each want-list FQDN into Edge-owned storage under that Component’s Host tree (not Workload-authored Route SoT). Never Workload-owned and never ACME-mutated.
_Avoid_: Domain Route, Edge Route, vhost (when you mean this Edge-owned front); Workload Route

**Workload** (alias **workflow**):
An operator-provided Host tree that combines an **Artifact** with Propraetor-internal **Workload Manifest** and **Binding**, declares **Intent**, and may author **Declarations** for Components. Identified by the basename of its Environment directory (immediate non-hidden child of the Environment); **Mirror** materializes it onto Host Volume `workloads/<basename>/` regardless of Source, with optional nested **Persist**; consumers read known siblings selectively. Canonical Service Network hostname is that basename (except the reserved dial names `database`, `cache`, and `identity`). Does not gather peers or fulfill other Workloads’ Declarations; not Fabric; not a Component; never installed during Initial Host Provisioning. **Workload** is canonical in docs and code; **workflow** is an accepted conversational alias.
_Avoid_: App, service, container, backend, Component, Fabric, Artifact (when you mean the Environment-placed whole including Manifest and Binding)

**Artifact**:
The portable subset of a **Workload** shape: **Provides** + **Requires** + content (directories, units, route fragments). Missing Propraetor-internal **Workload Manifest** and **Binding**. For `Source` zip the Artifact is zip root after obtain (and after an optional single-directory peel); the Environment Workload directory is Manifest + Binding (plus the `.zip` when obtain is a path) — `provides.json` / `requires.json` there fail closed. For `internal` the Artifact lives inline under the Environment Workload directory beside Manifest and Binding.
_Avoid_: Package, bundle, Workload (when you mean the Environment-placed whole); zip (when you mean the concept, not the Source form)

**Provides**:
A Workload **Declaration** of what the Artifact offers: open map of directories to materialize onto the Host Workload tree; route fragment paths offered for Edge (path → human description); optional permission catalog for Identity (key → human description); optional `oidc_callback` path (value is the path, `/…` only). Declared ⇒ used; omit ⇒ absent — no `false`. Non-empty `permissions` means this Workload contributes permission keys into the Environment-scoped Identity audience; those keys must be unique across Workloads in that Environment. For API-level access control, the operator must include the mandatory per-API marker permission key `${workload-slug}:api` in this Workload’s `permissions` map, and the API authorization layer must require that marker key. Propraetor only constrains issued tokens by requested scope keys; API-side authz must enforce the marker key. All other permission keys in this Workload’s `permissions` map must follow the convention `${workload-slug}:${permission}` (where `${permission}` is the operator-chosen capability identifier). Route fragments are a separate channel into Edge-owned storage, not Workload-tree Route SoT. Descriptions are human-only except `oidc_callback`, whose value is the path.
_Avoid_: exports, offers, routes/ directory SoT (retired), Manifest (when you mean this Declaration); scopes (wire encoding of permission keys); oidc_logout_callback (not gathered)

**Requires**:
A Workload **Declaration** of what the Artifact needs from Propraetor: environment variable names the process expects (name → human description); required booleans `database`, `cache`, and `identity`; optional `permissions` map (key → human description) for an OIDC client. Descriptions are human-only. Binding remaps Environment Configuration bag keys onto those names; Database gathers `database: true` and Cache gathers `cache: true` when Intent is **run**. Identity gathers `identity: true` with Provides and/or Requires `permissions` as in **Identity**; client Required keys may span multiple APIs. Tokens are limited by the permission keys granted into the client (including each target API’s mandatory marker key `${workload-slug}:api`). `identity` with neither catalog nor client permissions fails closed.
_Avoid_: dependencies, needs, Manifest environment / Manifest database (retired); oidc (boolean name)

**Binding**:
Propraetor-internal, Environment-placed SoT that resolves a Workload’s **Provides** / **Requires** against that Environment: FQDN → ordered Provides route paths, and Environment Configuration bag key → Requires environment name. Full fulfill only — every Provides route path in at least one FQDN array; every Requires environment name exactly one remap RHS; FQDNs ⊆ Domain want-list. Binding FQDNs do not determine token audience/resource; the Identity audience is Environment-scoped. An OIDC client may have many FQDNs (each callback URL is `https://<fqdn>` plus Provides `oidc_callback`). No permissions map on Binding. Not a Declaration; not part of the Artifact.
_Avoid_: attach.json, attachment, Declaration (when you mean this resolution file); client-cert binding (Database publish path); wildcard / per-key permission Binding

**Source**:
The Workload Manifest’s required origin of the Artifact: `internal` (Artifact is the Environment Workload directory) or zip (Artifact is zip root after obtain, peeled to a sole top-level directory when that directory contains Provides). Zip obtain is a relative `.zip` path under that Workload directory (nested segments allowed; no `.` / `..` or absolute; suffix case-folded), or an unauthenticated http(s) zip URI (any host, including loopback; suffix case-folded); after obtain, path and URI share extract. Path obtain names a regular file, not a symlink. A Workload directory may itself be a symlink across Environments; no symlink under a Workload directory may resolve outside it (operator and Host). No omit; non-zip origins are not v1.
_Avoid_: package URL, fetch, git, `file://`, public URI (when you mean unauthenticated http(s))

**Workload Manifest**:
A Workload-owned declaration that is the source of truth for that Workload’s Intent (**run** or **stop**), with an optional human-only `description` ignored by all automation, and a required **Source**. It does not name the Workload, claim DNS names, feed ACME, select Environment Configuration keys, declare Database need, or carry secret values or other runtime/unit config bytes; those concerns live on **Provides**, **Requires**, and **Binding**. Operator-authored units live in the Artifact under `systemd/` (Quadlet sources and native units in one bag).
_Avoid_: Manifest (bare), spec, compose file, workload config (when you mean this declaration)

**Workload Intent**:
The Manifest’s post–Workload Setup expectation — what must be true after Setup succeeds; never Host status or a report of what is currently on the server. Applies to the whole Workload-owned unit set under `systemd/` and that Workload’s bound Route Declarations. **run** (Always-on `.pod`, `.kube`, Always-on `.container` without `Pod=`, and native Always-on `.service` are started; Always-on `.container` with `Pod=` are expected started via their pod unit, not as independently Setup-checked units; On-demand units Armed; Ensure units ensured; bound Route Declarations offered for Edge to gather — zero Routes is valid; HTTP semantics are whatever those fragments declare inside the Domain front, not Propraetor-generated shells; reachability is not a Setup success criterion; Requires `database: true` is offered for Database fulfillment; Requires `cache: true` is offered for Cache fulfillment; Requires `identity: true` is offered for Identity fulfillment — catalog, client, and grants are created or updated), or **stop** (the same Always-on units that **run** starts are stopped; Always-on `.container` with `Pod=` are expected stopped via their pod unit, not as independently Setup-stopped units; On-demand Disarmed; Ensure resources left in place; bound Routes are not offered for Edge fulfillment — Domain front serves only its Edge baseline — today `/healthcheck` and miss behaviour as configured there — not a Propraetor-managed 503; Database binding is not offered for fulfillment; Identity unpublishes the Workload binding and leaves Identity interior catalog, client, and grants). Destroying Host Workload trees and associated Host state is not an Intent — that is **Orphan Reap** only.
_Avoid_: Workload Desired State, desired state, running, stopped, trashed, active, disabled, remove, status, phase, current state (when you mean this Manifest field); trash (retired Intent)

**Always-on**:
A Workload unit kind expected to stay started while Intent is **run** (`.pod`, long-running `.container` / `.kube`). Classified by authored file kind; a `.container` with `StartWithPod=false` is On-demand, not Always-on. A long-running `.container` with `Pod=` remains Always-on; under Intent it is tied to its pod unit (see **Workload Intent**), not a separate Setup-checked unit.
_Avoid_: long-running, daemon, continuous (when you mean this kind)

**On-demand**:
A Workload unit kind expected to fire on a condition while Intent is **run**, not to stay continuously executing (native `.timer` / oneshot `.service`, or job `.container` with `StartWithPod=false`, all under `systemd/`). Supported timer-job pattern uses `StartWithPod=false` — not an Always-on member left dead in the pod. systemd `Type=oneshot` is an implementation detail of some On-demand units, not the domain term.
_Avoid_: oneshot (when you mean this kind), scheduled job, triggered job

**Ensure**:
A Workload Quadlet unit kind expected to exist as a provisioned resource while Intent is **run** (`.volume`, `.network`, `.image`, `.build`, `.artifact`) — create/pull/build once; not left as a long-running process. **stop** does not tear the resource down; unit files remain until **Orphan Reap**.
_Avoid_: On-install, provision, oneshot (when you mean this kind)

**Armed**:
The Intent-**run** expectation for an On-demand unit: installed and enabled so its condition can fire; job payloads installed but not started by Workload Setup.
_Avoid_: enabled, active, started (when you mean this expectation)

**Disarmed**:
The Intent-**stop** expectation for an On-demand unit: not enabled to fire; any in-flight job instance stopped.
_Avoid_: disabled, stopped, inactive (when you mean this expectation)

**Orphan Reap**:
The sole operation that permanently removes a Workload’s Host state when that basename is not present in the Environment’s discovered Workload set (no immediate non-hidden directory under `environments/<slug>/`), including that Workload’s Host Volume owner tree (SoT and **Persist**), Platform User units, and EnvironmentFile trees (Database and Identity fulfillment for that basename is dropped on the next Component Setup `post-workloads`). Distinct from **Mirror** (which leaves orphans alone). Not an Intent.
_Avoid_: Purge (retired), Mirror, garbage collection, gc, prune (bare); trash (retired Intent)

**Service Network**:
The private container network on a Host that Components and Workloads join so they can reach each other by name. A **Fabric** member applied by **Fabric Setup** — not a Component and not owned by the Edge. Distinct from the provider Firewall.
_Avoid_: Podman network, bridge, CNI (implementation); network (bare — ambiguous with Firewall / provider networking); Component (when you mean this Fabric member)

**Escape Hatch**:
An operator-owned deviation from a soft Workload interaction convention that remains possible on the Host but is unsupported: Propraetor does not teach, scaffold, or Acceptance-test it, and ownership/Setup/**Orphan Reap** stay on the default contract. Not a supported alternate pattern, not a way around a hard Host-shape floor, and not a compatibility promise if soft conventions later gain optional enforcement. Wiping a Workload’s Host **Persist** (or whole Host owner tree) while keeping that basename in the Environment is not a product path — supported destroy is remove the Environment directory then **Orphan Reap**; any in-place Host wipe is Escape Hatch at best.
_Avoid_: workaround, exception, override, unsupported pattern (when you mean this named stance); supported deviation, documented alternate (those imply Propraetor owns the pattern); Purge / trash (retired product destroy path)

**Route**:
A Workload-offered **Declaration** for Edge: an Edge config fragment in location context (not a full TLS `server`) listed under **Provides** `routes` and attached to a Domain front only via **Binding**. Edge Component Setup gathers Intent-**run** bound Routes and fulfills them into Edge-owned storage for Domain fronts to include; Intent **stop** (or missing Binding/Provides) means Edge does not fulfill that Workload’s Routes. Every Provides route path must appear in at least one Binding FQDN array or fulfillment fails closed; Binding FQDNs must be on the Domain want-list. Zero Provides routes is valid. Not projected from the Manifest, not a hostname claim field, and not authored SoT under Workload-tree `routes/` with FQDN-as-filename. Edge ACME does not generate or mutate Routes; Domain fronts remain Edge-owned; Workload Setup does not write Edge interior.
_Avoid_: Vhost, upstream, location block, snippet, server block (when you mean this Workload attachment); Domain front; projected Route, generated shell, interior (removed Propraetor Route features); Declaration (when you mean only this kind); FQDN-as-filename Route (retired)

**Platform User**:
The Host login account that runs the platform’s rootless user Quadlets (linger enabled so user systemd stays up without an interactive session) and owns the **Platform journal**. Created by Initial Host Provisioning on public Hosts — account and linger only, not Quadlet units. Unix account name: `platform`.
_Avoid_: Prefect User, prefect (user), propraetor (user), edge user, podman user, service account (when you mean this Host account)
