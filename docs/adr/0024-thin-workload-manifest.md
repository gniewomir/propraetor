# Thin Workload Manifest (intent + optional description and environment)

After operator-owned Routes (ADR-0022) and Domain-driven ACME (ADR-0023), the Manifest was still thick: required `name` / `upstream`, and Workload Setup invented a default nginx Quadlet from `upstream`. That contradicted a minimal Propraetor-specific surface and “no hidden Workload runtime defaults.” The Manifest is now required `intent`, optional human-only `description` (ignored by automation), and optional `environment` (array of **Environment Configuration** key names — omit or empty ⇒ that Workload consumes none; values never live in the Manifest; injection: ADR-0035). Strict allowlist — any other key fails Setup. Adding `environment` is a deliberate allowlist thicken: still thin (names only, no secret/runtime bytes, no unit config). Workload identity is the basename of the definition-tree directory that holds the Manifest. Operator-authored units live in sibling `quadlets/` and `systemd/` (by consumer; parallel to `routes/`); missing/empty either is valid. Setup installs units under authored basenames into the matching Platform User directories (`quadlets/` → Quadlet dir; `systemd/` → native user systemd), stores SoT on the Host Volume, reconciles on Intent **run**, stops Always-on / Disarms On-demand on **stop** / **trash** (files until Purge), and refuses to overwrite any existing unit basename unless this Workload’s stored SoT already owns it. Purge deletes Intent-**trash** Workloads’ tree (including `routes/` / `quadlets/` / `systemd/` SoT), SoT-named units from both Host unit directories, installed Routes, and Environment Configuration install artifacts (ADR-0014 / ADR-0035) — not Domains/certs. Manifest `source` (external fetch) is deferred. Clean break (ADR-0018): no dual-read of `name` / `upstream` / retired keys. Workload shape and interaction policy (Escape Hatches, soft defaults, Host-shape floor) is ADR-0034.

**Authored `quadlets/` + `systemd/` + directory identity over Manifest `name`/`upstream` + Propraetor-minted units:** keeps native Quadlet/systemd/nginx as the Workload languages and makes graduation “copy the definition tree.”

**Defer `source` over shipping a fetch field now:** local `routes/` + `quadlets/` are enough; avoid a mini package manager before a real operator need.

**Strict allowlist over ignore-unknown:** thick leftovers must fail loud, not half-apply.

**Optional `environment` names over Manifest-held values or placeholders:** consume declaration stays glanceable and value-free; materialization is ADR-0035.

**Authored unit basenames (no `<workload>--` prefix) over Route-style renaming:** units stay graduation-friendly; uniqueness is enforced by refusing foreign basenames in the unit directory.

**Amended by ADR-0049:** optional boolean `database` (`true` ⇒ Declaration for the Database Component) is a further deliberate allowlist thicken — still thin (no secret/runtime bytes).
