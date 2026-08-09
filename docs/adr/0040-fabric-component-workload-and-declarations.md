# Fabric, Component, Workload, and Declarations

Propraetor’s Host-side ladder is **Substrate** → **Fabric** → **Component** → **Workload**. **Substrate** is the Host condition after IHP Done — everything required to run Fabric Setup (today: engine, Platform User, ports, Host Volume mount); not a Setup kind and not a peer of Fabric/Component/Workload. **Fabric** is the post-Substrate layer Components and Workloads require (today: Service Network only); **Fabric Setup** applies Fabric; IHP produces Substrate (including the mount) and is not Fabric. **Component** owns a shared resource and fulfills **Declarations** from agreed SoT (Workload trees and/or Environment config); no Workload Intent; Workload Setup does not perform Component fulfillment. **Workload** declares Intent and may author Declarations; does not gather peers. **Declaration** is the umbrella for gatherable claims (today: Routes; Domain assignment into Edge; later e.g. database needs). **Edge** remains a mandatory Component on public Hosts (product bit). Route Declarations live in Workload Host Volume SoT only; **Edge Component Setup** gathers Intent-**run** Routes and fulfills into Edge interior — refresh by re-running Edge Setup after Workload Setup or Purge (noop when unchanged). Day-to-day truth: `CONTEXT.md`.

**Amends:** ADR-0007 (Service Network is Fabric, not a Component peer of Edge); ADR-0010 (ensure path must distinguish Fabric Setup from Component Setup; network is not a Component); ADR-0022 (Setup that gathers Routes is Edge Component Setup — not Workload Setup installing into Edge). Operator-authored Route SoT under the Workload tree and Manifest-free projection stay as in ADR-0022.

**Rejected:** Collapsing Component and Workload into one kind; Workload Intent on Components; keeping Route fulfillment in Workload Setup; defining Fabric as “everything IHP does”; putting the Host Volume mount in Fabric; collapsing Substrate into Fabric or into the IHP Done gate.

**Amended by ADR-0041:** **Deploy** runs **Mirror** (and **Orphan Reap**) before **Component Setup** so Edge gather sees Environment Workload SoT in one pass; Host Volume paths and ensure packaging follow ADR-0041.

**Amended by ADR-0043:** **Deploy** runs Component Setup in two slots (`pre-workloads` then, after Workloads + Purge, `post-workloads`); Declaration fulfillment that depends on Workload identity is the post slot.

**Cutover:** glossary updated; Host cutover complete — Edge Component Setup gathers Routes; ensure distinguishes Fabric Setup vs Component Setup.
