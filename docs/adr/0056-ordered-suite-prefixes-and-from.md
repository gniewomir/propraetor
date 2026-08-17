# Four-digit ordered-suite prefixes and `--from`

Acceptance and Lifecycle cases are unique four-digit prefixes (`NNNN-short-name.sh`); `LC_ALL=C` filename sort is suite order (ADR-0005). Default gap is 100 (append last+100; insert with a spare). The thousands digit is magnitude, not a band id. `./test.sh <suite> [<case-selector>] [--from <token>] [--verbose] [--env <slug>]`: the positional selector remains exactly one case; `--from` runs that case through the end (inclusive). An all-digit token matches the numeric prefix (`100` == `0100`); otherwise a unique filename substring. Selector and `--from` are mutually exclusive. `--from` on Unit fails closed. List / resolve / slice live in one Module used by both ordered-suite runners. On non-test Acceptance, `--from` resolves on the full list then skips fixture-class cases (`SKIP`, including a named start); an explicit selector still refuses fixture-class (ADR-0042). Hard cut: two- and three-digit prefixes go away in the same change.

**Considered:** three-digit pad in place; mixed-width numeric/`sort -V`; thousands-as-band-ids (`1xxx` Host, `2xxx` Substrate); magic positional (`83+`). Rejected: pad-in-place left mixed width and duplicate prefixes; hidden numeric sort fights `ls`/git; band-ids in the thousands place fill a band at ten cases; overloading the selector.

Amends ADR-0005, ADR-0036, ADR-0039.
