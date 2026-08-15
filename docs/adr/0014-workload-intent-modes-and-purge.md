# Workload Intent modes and Host destroy

**Historical Intent-stop 503 / name-hold-as-reachability slice superseded by [ADR-0022](0022-operator-owned-routes.md)**; Intent field naming is ADR-0017. Body below is the rewritten current contract — not a dead ADR.

The Workload Manifest carries a **Workload Intent** (naming: ADR-0017; thin Manifest + Source: ADR-0024 / ADR-0053): **run** or **stop** only. **run** — operator-authored units up; bound Route Declarations (Provides routes attached by Binding) offered when authored (zero Routes valid); Edge Component Setup gathers and fulfills Intent-**run** Routes — HTTP semantics are whatever those fulfilled fragments declare. **stop** — those units stopped; bound Routes are not offered for Edge fulfillment (Edge default miss after Edge Setup re-gather, not a Propraetor 503); Workload data and Domain-scoped certificates preserved. Host destroy is **Orphan Reap** only: remove the Environment Workload directory, then Deploy reaps Host Volume owner tree (SoT + Persist), Platform User units, and EnvironmentFile trees; Database fulfillment for that basename drops on Component Setup `post-workloads`. Wiping Host state while keeping the Environment directory is Escape Hatch at best (unsupported) — ADR-0054. ACME want-list is Domain assignment (ADR-0023), not Manifest claims — Setup and Orphan Reap do not rebuild it.

**Intent stop drops Edge fulfillment via Edge Setup (no Propraetor 503):** process lifecycle parks without Propraetor-owned Edge HTTP shells (Edge default miss — ADR-0022 / ADR-0040); Domain/certs stay.

**Orphan Reap over Intent trash + Purge:** one Environment-absence destroy path; no Manifest destroy Intent and no Deploy Purge step (ADR-0054 / #217).

**Amended by ADR-0041:** Host Workloads absent from the Environment are removed by **Orphan Reap**. **Mirror** materializes Environment Workloads and leaves orphans alone.

**Amended by ADR-0054 / #217:** Intent values are **run**|**stop** only; Purge / Intent **trash** retired from product paths.
