# Workload Intent (not Desired State / Host status)

The Workload Manifest declares **Workload Intent** — the post–Workload Setup expectation of what must be true after Setup succeeds — never observed Host status or a report of what is currently on the server. Values are **run** or **stop**; the Manifest field is `intent`. Mode behaviour and Host destroy (Orphan Reap only) stay as in ADR-0014 / ADR-0054. Domain prose uses Intent wording only (no “running/stopped Workload”).

**Workload Intent + `run`|`stop` over Workload Desired State + `running`|`stopped`:** Desired State and participial values read as “what is true on the server now”; Intent and verb-form values keep a declarative post-Setup expectation without sounding like Host status.

**Manifest key `intent` only (reject `state`, no dual-read):** wire format matches the glossary; no standing out-of-repo Manifests required a transition window.

**Strict Intent prose over mixed past-participle shorthand:** one vocabulary in glossary, ADRs, and tests.

**Amended by ADR-0054 / #217:** Intent **trash** retired; values are **run**|**stop** only.
