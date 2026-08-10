# Environments root is optional Operator Configuration

Default Environment SoT stays under repo `environments/<slug>/` (ADR-0033). Operators may relocate that **Environments root** (the directory whose children are `<slug>/` trees) via optional Operator Configuration `PROPRAETOR_ENVIRONMENTS_ROOT` — absolute or `~/…`, existing directory — without changing Environment identity (`--env` / workspace). When set, the configured root **fully replaces** repo `environments/` for every Environment-tree reader (shell and Terraform Domain loading alike); missing `<root>/<slug>/` fails closed. No merge or fallback to the repo tree (avoids split-brain Adopt vs plan). Unset keeps today’s layout.

**Suites:** Acceptance and Lifecycle refuse to run when the knob is set — those contracts assume the repo tree (fixtures, git porcelain, `domains.override.json` Lifecycle hook under ADR-0021). Unit Tests clear ambient `PROPRAETOR_ENVIRONMENTS_ROOT` unless a case exports a temp root deliberately.

**Allowlist / load:** same repo-root `.env` baseline and shell-wins rules as ADR-0038; document in `.env.example`. Apply / Park / Teardown export the resolved absolute root into Terraform (`TF_VAR_environments_root`) so `domain.tf` does not hard-code only `${path.root}/../../environments`.

**Unit ambient:** the Unit suite exports `PROPRAETOR_UNIT_TEST=1` and unsets `PROPRAETOR_ENVIRONMENTS_ROOT` so repo-root `.env` cannot re-inject the knob via `operator_dotenv_load` when a case invokes Apply-seam entrypoints; cases that need a temp tree export `PROPRAETOR_ENVIRONMENTS_ROOT` themselves (process env wins).

**Amends:** ADR-0033 (default location, relocatable), ADR-0038 (allowlist), ADR-0021 path prefix (assignment still `<environments-root>/<slug>/domains.json` with override prefer).

## Considered

Domain-assignment-only injection; test-only / undocumented seam; shell-only then Terraform later; path-to-one-Environment-directory; fallback to repo tree when slug missing; suites honor or silently ignore the knob. Rejected — incomplete SoT, split-brain, dual identity, or non-deterministic suites.
