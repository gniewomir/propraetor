# Artifact Source kinds (git, local) and optional Artifact Build

Operators need to materialize a package from another repository (or a workstation projects tree) as a Workload Artifact, and — when that package declares how — run an isolated build that yields deployable content without Propraetor learning each stack’s toolchain. Manifest **Source** becomes a discriminated **kind**. Optional **Artifact Build** is declared only by `build.json` at the Artifact root; Propraetor triggers a container and overlays declared outputs — it never reads `package.json` or other recipe files. Obtain and Artifact Build run on **Host materialize only** (same seam as zip); after resolve, the Host still sees one Artifact (Provides + Requires + content) and today’s Binding / Setup path.

**Source kinds (v1):**

- **`internal`** — unchanged: Artifact is the Environment Workload directory beside Manifest and Binding. Authored as the string `"internal"` (same as today).
- **`zip`** — unchanged: relative `.zip` under the Workload directory or unauthenticated http(s) zip URI (string forms as today); Environment tree is Manifest + Binding (+ path zip); peel rules as ADR-0053.
- **`git`** — object `{ "kind": "git", "url", "commit", "path" }`. Environment tree is Manifest + Binding only (≈ zip layout). Required: https `url`, full-sha `commit`, `path` (package / Artifact root inside the repo; `.` allowed). Host fetches with `git` over HTTPS; missing `git` fails closed. No branch, SSH, or credentials in v1 (private remotes deferred). Pin is mandatory.
- **`local`** — object `{ "kind": "local", "path" }`. Unpinned on purpose (deploy-time materials). `path` is **relative** to Operator Configuration **Projects root** (`PROPRAETOR_PROJECTS_ROOT`: absolute or `~/…`, existing directory). No `..`, no absolute Manifest path, no escape outside the Projects root. Operator resolves and **stages** a copy onto the Host Workload tree; the Host never reads the workstation path. Allowed in any Environment. Missing Projects root when Source is `local` fails closed.

**Artifact Build:** `build.json` only at Artifact root. Missing ⇒ no build (materials are the Artifact). Present ⇒ validate and run fail-closed. v1 keys: `image` (author-owned string; tag or digest; no Propraetor digest enforcement), `command`, `output` (one or more paths relative to Artifact root). Build runs in a container with egress allowed. Harvest is **overlay** into `output` only — never replace `provides.json`, `requires.json`, `build.json`, `systemd/`, or `persist/` from build output. Provides / Requires live at the pointed-at Artifact root (git `path` or staged local / internal tree) before overlay. v1 rebuilds on every materialize (no cache). Distinct from Ensure Quadlet `.build` (runtime images under Intent).

**Amends:** ADR-0053 (Source kinds beyond `internal` / zip; Mirror obtain + optional Artifact Build before Provides directories apply); ADR-0038 / ADR-0051 (Operator Configuration allowlist gains Projects root).

**Tracking:** #259

**Rejected:** Propraetor reading `package.json` / inventing npm; host-native (non-container) build; materialize-time build on the operator as a second path; local commit pinning; absolute local paths in Manifest; Host reading operator filesystem paths; private / SSH git in v1; build output replacing Artifact contracts; folding Artifact Build into Ensure `.build`; digest-mandatory builder images in v1; build result cache in v1.

**Deferred:** private remotes (Operator Configuration credentials); build cache keyed by commit + `build.json` + image; zip integrity pinning (unchanged deferral from ADR-0053); tighter overlay ⊆ Provides `directories` check.
