# Opaque Workload Mirror bag

**Mirror** (and singular **Workload Setup** SoT sync) recursively upsert each Environment Workload directory onto Host Volume `internals/workloads/<basename>/` as an opaque bag (`cp -a` semantics: hidden entries included, symlinks preserved as links). Discovery is every immediate non-hidden Environment directory (ADR-0033) — not gated on `manifest.json`. Mirror does not filter siblings or enforce definition-tree shape; consumers stay selective and flat on known siblings. Manifest absence/invalidity fail-closes at **Workload Setup** (and thus **Deploy**), not at Mirror. One projection rule: Setup stages/syncs the same bag Mirror would, then applies Intent. Durable bytes stay under `data/workloads/<name>/` with no bag heuristics.

**Amends:** ADR-0041 (retires allowlisted Mirror siblings and `manifest.json` discovery for Mirror / Orphan Reap / `ensure-workloads`).

**Rejected:** Keep Mirror allowlist (false contract; fought operator-owned trees and broke full-tree SoT noop when extras like `www/` existed); soft-skip Manifest-less dirs in batch Setup (second discovery rule; weakens **Deployed**); dereference or refuse symlinks at Mirror; strip in-tree dot entries (breaks paths like `.well-known`); recurse consumer gather/unit install into nested declaration dirs.
