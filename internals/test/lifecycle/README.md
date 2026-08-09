# Lifecycle Tests

Executable checks of Stack lifecycle operations that deliberately change Stack presence: **Park**, **Apply** after Park, and **Teardown**. Opt-in and destructive.

**Entrypoint:** `./test.sh lifecycle` — see [docs/agents/testing.md](../../../docs/agents/testing.md) (ADR-0036). Suite baselines: [ADR-0042](../../../docs/adr/0042-suite-baselines-and-test-isolation.md).

**Suite baseline (ADR-0042):** Stack **absent** (post-**Teardown**). Runner Teardown **before each case**. **test Environment only** (fail closed on any other `--env`). Suite start: after case inventory, type exact `teardown` once (before credential / Host work). Cases that need an Applied Stack **Apply** themselves. Slow by design.

**Not Acceptance Tests.** Acceptance asserts a **Deployed** Host and must not Park or Teardown. See `../acceptance/README.md` and the glossary terms Acceptance Test / Lifecycle Test / Unit Test.

## Status

- Stable Applied / Parked + Park → Apply round-trip: `10-park-apply.sh`
  (empty repeated Apply/Park plans; Cloud Project / Reserved IP / Host Volume /
  Domain identities; Host Volume marker; Host and Reserved IP memberships by
  lifecycle class)
- Parked Additive Domain happy path: `14-parked-additive-domain.sh`
  (case-owned Park; same override fixture as `15`; one normal Apply; prior Durables
  unchanged; fixture present; Recreatables restored; empty re-Apply; Teardown cleanup
  as in `15-additive-domain.sh`)
- Applied Additive Domain: `15-additive-domain.sh`
  (derived `domains.override.json` fixture; prior identities/memberships preserved;
  empty re-Apply; Teardown with override → drop override → committed re-Apply)
- Parked additive partial Apply recovery: `16-parked-additive-partial-apply.sh`
  (case-owned Park; same override fixture; Apply with invalid
  `TF_VAR_host_image` after Durable converge; restore default image → Apply;
  empty re-Apply; Teardown cleanup as in `15-additive-domain.sh`)
- Subtractive Durable fail-closed: `17-subtractive-durable.sh`
  (narrower `domains.override.json` drops lex-first committed apex; Apply fails with
  `prevent_destroy`; Durables unchanged; drop override → committed re-Apply; empty re-Apply)
- Teardown from Parked (Durables wiped, State empty): `20-teardown.sh`
  (case-owned Park → Teardown; Cloud Project, Reserved IP, Host Volume, Domain when
  configured). Applied→Teardown remains covered by additive-case cleanup (`14`/`15`/`16`).

Domain Durable asserts run when Domains are in State (declare them in `environments/<cloud-slug>/domains.json`; each case Applies from the absent suite baseline via `ensure_stack_applied`). With zero Domains configured, those asserts skip — Reserved IP / Host Volume coverage still runs. The Additive Domain case requires a non-empty committed Domain assignment (base apex for `lifecycle-test.<apex>`).

**Internal Domain override (maintainer / harness only):** if `environments/<slug>/domains.override.json` exists, production Domain loaders use it **instead of** `domains.json` (ADR-0021). Gitignored; not an operator flag. The suite baseline removes any leftover override before each case. Additive Domain Lifecycle cases may write a derived override (committed map plus `lifecycle-test.<lexicographically-first-apex>`), run Apply/Teardown while it is present, then remove it before re-Apply of committed Domains only.

## Run

Credentials must already be in the environment or root `.env` (`DIGITALOCEAN_TOKEN`, `PROPRAETOR_PUBLIC_KEY_PATH`, `PROPRAETOR_PRIVATE_KEY_PATH`, and `PROPRAETOR_ACME_EMAIL` when `environments/<slug>/acme.json` is present — same as `./apply.sh`; see ADR-0037 / ADR-0038 / ADR-0045).

```bash
./test.sh lifecycle                 # all Lifecycle Tests on the test Environment (default)
./test.sh lifecycle park-apply      # one slice (substring match on the filename)
./test.sh lifecycle teardown        # Teardown-focused case (suite still prompts 'teardown' once)
./test.sh lifecycle --env test      # same Environment as omitting --env (`default` also aliases)
./test.sh lifecycle park-apply --env test
```

**Environment (ADR-0042):** Lifecycle is **test-only** — no `--env` or `--env test` / `--env default` only; any other slug fail closed. Positionals first, then flags; flag order free (ADR-0039). The runner propagates the resolved Environment into nested `./park.sh` / `./apply.sh` / `./teardown.sh` so child calls cannot flip Environment.

Each case that needs an Applied Stack calls `ensure_stack_applied` first (Apply from absent / fresh / empty / Parked; no-op only if already Applied mid-case or outside the runner). Suite order is not a substitute — the runner baselines to Stack absent before each case and clears `domains.override.json` residue.

The runner asks for exact `teardown` once at suite start (every invocation wipes Durables between cases). Nested `./teardown.sh` confirms may still apply. Do not wire this into CI that assumes a standing Applied Stack. After a suite, leftover State may be whatever the last case left until the next Lifecycle baseline or a manual `./apply.sh` before Acceptance.

## Add a case

1. Add `NN-short-name.sh` in this directory.
2. Use observable outcomes (provider presence/absence, Reserved IP value, volume marker bytes, SSH reachability) — not Terraform internals. Exception: Teardown leftover emptiness may be asserted via empty State (glossary Teardown).
3. Document leftover Stack state in the case header (Parked vs Applied vs empty).
4. If the case needs Applied presence, call `ensure_stack_applied` (do not fail closed asking the operator to Apply first).
5. Source `lib/lib.sh` for `pass` / `fail`, provider Durable checks, and SSH helpers.

Non-case files in this directory (`lib/`, `run.sh`, this README) are not executed as cases. Shared helpers and their Unit Tests live under `lib/`.
