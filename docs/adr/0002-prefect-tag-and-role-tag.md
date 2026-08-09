# Propraetor Tag and Role Tag stay separate

Propraetor uses two DigitalOcean tags, not one. The Propraetor Tag (`propraetor-<slug>`, e.g. `propraetor-test`) marks taggable resources as belonging to Propraetor in that Environment; the Role Tag (`propraetor-<slug>-public-web`, e.g. `propraetor-test-public-web`) selects Hosts for policies such as the public-web Firewall. Collapsing them would couple “everything Propraetor owns” to “Hosts that should get the public-web Firewall,” so Propraetor Tag membership and policy attachment stay independent.

**Amended by ADR-0019:** tag strings are Environment-prefixed account-unique names (same derivation as other Stack cloud names); the separation decision is unchanged.
