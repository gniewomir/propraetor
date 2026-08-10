# Environment-first repo layout and Workload Setup bind

Committed Environment intent lives under root `environments/<slug>/`, not under `config/environments/` with a sibling root `workloads/`. Domains and Workloads share one Environment tree so membership and per-Environment divergence are expressible without inventing a second axis.

**Layout rule:** under `environments/<slug>/`, every **file** is Environment configuration or documentation (`domains.json`, `domains.override.json`, …); every **immediate directory** whose name does not start with `.` is a Workload definition tree (identity = directory basename). Dotdirs are ignored (not Workloads). No `workloads/` segment — that nesting added depth without gain. Discovery for Mirror / Orphan Reap / batch Setup is that directory set (ADR-0047 — not gated on `manifest.json`).

**Out of scope:** the internal shape of a Workload definition tree (Manifest wire form, `routes/`, `quadlets/`, and any later siblings). Those remain governed by existing Workload ADRs; this decision only places the tree under the Environment. A Manifest-less directory is a lazy fail when Setup names it — not an early layout lint or Mirror skip.

**Workload Setup bind (operator contract):**

- Setup accepts a **Workload name** only: `./internals/ensure-workload.sh <name> [--env <slug>]` → `environments/<active-slug>/<name>/`. Arbitrary Manifest paths are rejected (fail closed).
- The Environment tree is the **Setup source** for Intent. Absence from the tree does not invent Intent or Purge; Host Workloads whose basename is not in the Environment are removed by **Orphan Reap** (on **Deploy**, distinct from Intent-**trash** **Purge** — ADR-0041).
- Stack **Apply** stays separate from Workload Setup (ADR-0032).
- Acceptance fixtures write ephemeral Workload directories under `environments/<active-slug>/`, Setup by name, and remove them on exit — same contract, no override path.

**Setup converge vs noop:** Workload Setup is idempotent. If the definition tree equals the Host Volume stored Workload tree, Setup is a noop for SoT (Manifest, Route Declarations, units) — except Intent **run** still converges when required Quadlet unit *files* are missing on the Host (e.g. after Park/Apply recreates the Host while Host Volume SoT survived). Workload Setup does not write Edge interior; Route fulfillment refreshes on Edge Component Setup (ADR-0040). Live pod/container health is not part of the noop gate; reboot/crash recovery is linger / unit `Restart=` / diagnostics, not Setup. Setup starts units only when it converges and Intent is **run**.

**Host Volume:** Mirrored definition SoT under `internals/workloads/<name>/`; durable runtime under `data/workloads/<name>/` (ADR-0041). Setup identity remains the definition-tree basename.

**Amended by ADR-0041:** Environment absence is **Orphan Reap** (not deferred operator risk); Host Volume splits Mirrored SoT from durable `data/`.

**Amended by ADR-0047:** discovery is directory-based; Mirror/Setup project an opaque recursive bag.

**Amended by ADR-0051:** repo `environments/` remains the default Environments root; optional Operator Configuration may relocate that root (full replace when set).

**Considered:** keep root `workloads/` + `config/environments/`; `workloads/environments/…`; `environments/<slug>/workloads/<name>/`; path-based Setup; Setup inside Apply; environments linter for incomplete dirs; noop gated on live unit/pod health; deferring “not in tree ⇒ remove” forever (overturned — ADR-0041 Orphan Reap). Rejected for locality, footguns, or premature surface.

Amends ADR-0021 (Domain assignment path) and ADR-0032 (root declarations). Clean break (ADR-0018).
