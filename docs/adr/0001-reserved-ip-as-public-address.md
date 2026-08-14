# Reserved IP as the public address

Public Hosts are reached via a Reserved IP assigned to the Host, not via the Host’s own public IP. Domains must point at a stable address that survives rebuilds, **Park**, and other changes in Propraetor infrastructure; the Host’s ephemeral public IP does not provide that. The address is a **Durable**: Park keeps it; Apply reassigns it to the new Host; only **Teardown** releases it (ADR-0025).
