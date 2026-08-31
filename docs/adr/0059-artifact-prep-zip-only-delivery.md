# Artifact Prep and zip-only Host delivery

Every Workload reaches the Host as a zip: **Artifact Prep** evaluates committed Manifest **Source** on the operator machine, obtains or builds **materials**, produces a deployable Artifact zip, and stages it under `environments/<slug>/.artifact-cache/`. **Deploy** / **Mirror** consume only that staged zip — they do not evaluate **Source**, fetch git, read Projects root, or run **Artifact Build**. Host delivery is zip-only; Manifest **Source** is prep-facing only and is **never rewritten** by Prep.

**Artifact Prep** runs per Environment before any Deploy step that materializes Workloads (Deploy always invokes Prep as phase 0; a standalone Prep entrypoint exists for iteration). On each Prep it re-evaluates every Workload **Source**, runs the full obtain/build pipeline (no “skip build because cache hit”), normalizes to a Propraetor Artifact zip (for `zip` Source: extract → validate layout → re-zip; for tree Sources: zip Artifact root after optional **Artifact Build**), SHA-256-hashes the zip bytes, writes `.artifact-cache/<basename>-<sha256>.zip`, and writes **Artifact staging** `.artifact-cache/<basename>.staging` as a single line of SHA-256 hex (64 chars; zip path is derived). Prep fails closed when obtain/build fails. Older checksum-named zips may remain in the cache directory; they are not the deploy target unless referenced by a current staging record.

**Checksum** is the **output content hash** (SHA-256 hex of the staged zip bytes). It is the deploy identity for that Workload on this run — what Mirror must land on the Host — not an input pin and not a skip-build key. Prep always rebuilds; Mirror always extracts and applies Provides (Host checksum no-op deferred).

**Manifest Source (prep-facing)** declares where **materials** or a finished Artifact come from. Discriminated kinds (v1):

- **`zip`** — finished Artifact zip: relative `.zip` under the Workload directory or unauthenticated http(s) zip URI. Prep extracts, validates Artifact layout, re-zips — staged checksum is of the normalized Propraetor zip. Optional `build.json` inside the obtained Artifact root runs **Artifact Build** before re-zip (same overlay rules as ADR-0058).
- **`git`** — `{ "kind": "git", "url", "commit", "path" }`. Prep HTTPS-fetches repo at `commit`; **materials** = repo tree; Artifact root = `path` inside it.
- **`local`** — `{ "kind": "local", "path" }`. Prep resolves **Projects root** + relative `path`; **Project root** = git toplevel containing that Artifact; **materials** = Project root tree; Artifact root = path inside it.
- **`internal`** — string `"internal"`. The Environment Workload directory is the authoring home for the whole Workload: **materials** = that directory excluding `manifest.json` and `binding.json` only (inline `provides.json`, `requires.json`, `systemd/`, route fragments, and other Artifact bytes are allowed and are Prep input). Optional `build.json` at the Artifact root runs **Artifact Build** before zipping. Never zip `persist/`. Host delivery is still the staged zip from **Artifact cache**.

Optional **`build.json`** at the Artifact root (inside materials): Prep runs containerized build on the **operator** with materials visible; overlay `output` only; never replace `provides.json`, `requires.json`, `build.json`, `systemd/`, or `persist/` from build output. Distinct from Ensure Quadlet `.build`.

**Environment tree gate (Source-kind):** for **`internal`**, inline Artifact contracts in the Environment Workload directory are allowed (operator fail-early still applies symlink and reserved-path rules). For **`git`**, **`local`**, and **`zip`**, Environment Workload trees are Manifest + Binding only — inline `provides.json` / `requires.json` fail closed (operator and Host). Staged zips and `.artifact-cache/` are operator-local (gitignored); **Source** stays committed.

**Mirror** (and singular `ensure-mirror` / `ensure-workload`) upserts Manifest + Binding, reads **Artifact staging** for each Workload, ships the referenced `.artifact-cache/<basename>-<sha256>.zip`, extracts on the Host (ADR-0053 peel rules), applies Provides directories, and retains the zip on the Host Workload tree. Missing staging record or missing referenced zip fails closed — no Host Workload materialization without Prep.

**Amends:** ADR-0053 (Host obtain is staged zip only; Environment tree gate is Source-kind; **Source** is prep-facing); ADR-0041 (Deploy requires Artifact Prep before Mirror; Prep is Deploy phase 0); ADR-0038 (Projects root remains Operator Configuration for Prep `local` Source).

**Supersedes:** ADR-0058 Host obtain/build/materialize path only — Prep retains obtain/build semantics from ADR-0058 on the operator; Host side is cut.

**Rejected:** Prep rewriting Manifest **Source**; Host evaluation of **Source**; symlink from Workload dir to `.artifact-cache/`; using checksum as skip-build cache key; optional Prep before Deploy; Host-side rebuild from **Source** alone; Host Workload materialization without valid **Artifact staging**; blanket “Manifest + Binding only” for **`internal`** Workloads.

**Deferred:** Host-side record of last-deployed checksum for extract no-op; deterministic-zip enforcement; `.artifact-cache` GC; zip integrity cross-check beyond content-addressed filenames; private git remotes.

**Tracking:** #259
