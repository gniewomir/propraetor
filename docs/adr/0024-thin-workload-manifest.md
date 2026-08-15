# Thin Workload Manifest (intent + Source + optional description)

After operator-owned Routes (ADR-0022) and Domain-driven ACME (ADR-0023), the Manifest was still thick: required `name` / `upstream`, and Workload Setup invented a default nginx Quadlet from `upstream`. That contradicted a minimal Propraetor-specific surface and “no hidden Workload runtime defaults.” The Manifest is now required `intent`, optional human-only `description` (ignored by automation), and required **Source** (`internal` or zip — relative `.zip` path under the Workload directory or an unauthenticated http(s) zip URI — ADR-0053). Strict allowlist — any other key fails Setup. Workload identity is the basename of the Environment directory that holds the Manifest. Environment Configuration selection and Database need live on **Requires** + **Binding**, not the Manifest (ADR-0035 / ADR-0049 / ADR-0053). Operator-authored units live in the Artifact’s one `systemd/` bag (Quadlet + native; ADR-0054); after projection the bag must contain ≥1 allowlisted unit. Setup installs via kind-prefixed Quadlet directory symlink farm + native unit copy, reconciles on Intent **run**, stops Always-on / Disarms On-demand on **stop** (files until Orphan Reap), and refuses to overwrite any existing unit basename unless this Workload’s stored SoT already owns it. Host destroy is **Orphan Reap** only (Environment absence — ADR-0014 / ADR-0054). Clean break (ADR-0018): no dual-read of `name` / `upstream` / retired `environment` / `database` / deferred-source / Intent `trash`. Workload shape and interaction policy (Escape Hatches, soft defaults, Host-shape floor) is ADR-0034.

**Authored `systemd/` + directory identity over Manifest `name`/`upstream` + Propraetor-minted units:** keeps native Quadlet/systemd/Edge config as the Workload languages and makes graduation “copy the Artifact.”

**Amended by ADR-0054 / #216 / #217 / #218:** unified `systemd/`; Intent **run**|**stop** only; Orphan Reap–only destroy.

**Required Source over deferring fetch:** external ⊂ internal needs an explicit Artifact origin; Mirror materializes regardless of Source (ADR-0053). Zip integrity pinning remains deferred.

**Strict allowlist over ignore-unknown:** thick leftovers must fail loud, not half-apply.

**Requires + Binding over Manifest `environment` / `database`:** Artifact stays free of Propraetor bag keys and FQDNs; selection/remap is Environment-local (ADR-0053).

**Authored unit basenames (no `<workload>--` prefix) over Route-style renaming:** units stay graduation-friendly; uniqueness is enforced by refusing foreign basenames in the unit directory.
