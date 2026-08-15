# Pod-centric Always-on Intent apply

Workload Setup was restarting every Always-on unit in SoT order, which for Quadlet `Pod=` containers often meant container-before-pod and a `BindsTo` dependency failure. Intent apply for Always-on is now pod-centric: Setup restarts/stops `.pod` (and other non-membered Always-on units — bare `.container`, `.kube`, native Always-on `.service`) and does not restart, stop, or assert Always-on `.container` units that set `Pod=`; Quadlet’s pod graph owns those members. Every `.container` `Pod=` value must name a `.pod` or `.kube` basename in that Workload’s `systemd/` bag (fail closed). On-demand Arm/Disarm stays Setup-driven even with `Pod=`. Soft one-pod-per-Workload convention (ADR-0034) is unchanged — not a hard “≥1 pod” floor. Rejected: sorting pods before containers inside Always-on (Propraetor re-owns ordering Quadlet already encodes); retry/mask around the race; renaming files for sort luck.

Day-to-day Intent wording: `CONTEXT.md` (**Workload Intent**, **Always-on**).

**Amended by ADR-0054 / #216 / #218:** `Pod=` membership is validated against the unified `systemd/` bag (retired `quadlets/`).
