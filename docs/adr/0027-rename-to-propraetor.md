# Rename the project to Propraetor

**Executed:** Teardown-first cutover — empty provider State before Apply under the new name.

The former project name **Prefect** collided with [prefect.io](https://www.prefect.io/) (workflow orchestration): same spelling, overlapping “run infrastructure” neighborhood. Every search, README, and conversation paid a standing tax. The project is **Propraetor** (*propraetor*: delegated provincial command on the same Roman magistracy ladder as *praefectus* / *legatus*). Rejected: keep Prefect; **Legate** (NVIDIA HPC runtime owns the name); other offices with live software brands (**Consul**, **Praetor**, **Praeses**, …).

**Posture (ADR-0018):** one clean break. No dual-read of old/new names, no deprecation aliases, no “Prefect means Propraetor” shim. Callers, docs, provider labels, and tests moved in the same change.

**Execution checklist** (completed under the Teardown-first assumption — no live Adopt/rename of existing provider facts):

1. **Ubiquitous language** — Glossary and domain terms use Propraetor; Host-local paths/user stay function-named (ADR-0032).
2. **Operator surface** — Help text, script/CLI branding, Environment-scoped defaults.
3. **Host-local identity** — **Not re-branded** (ADR-0032): `/var/lib/host-volume`, `platform`, `/tmp/platform-*`, etc.
4. **Provider-visible names** — Account-unique labels use `propraetor-${environment_slug}` forms (`naming.tf`); fresh Apply after Teardown.
5. **Contracts & fixtures** — Acceptance / Lifecycle / Adopt golden strings.
6. **Repo & agent chrome** — Rules and research prose; prefect.io disambiguation removed where obsolete. Historical ADR *filenames* that contain the old name may remain.
7. **Verify** — Lib/unit gates green; live Apply / Park / Acceptance / Lifecycle on a disposable Environment remains the operator’s post-merge matrix.
8. **Close** — No transitional half-life.

**Out of scope:** compatibility bridges; renaming unrelated third-party tools; claiming domains/package names beyond the operator surface; GitHub repository rename (optional chrome); re-deciding Host-local function names from ADR-0032.

**Revisit if:** an external contract has already stabilized on the old name (then treat that surface as the ADR-0018 exception and ask before breaking it).
