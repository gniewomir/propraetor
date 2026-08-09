# Stale Environment known_hosts after Host recreate

ADR-0046. Use this when operator SSH or Deploy fails with OpenSSH host-key mismatch against an Environment that still has a Reserved IP.

## Symptom

```text
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
Host key for [x.x.x.x]:9417 has changed and you have requested strict checking.
Host key verification failed.
IHP Done wait interrupted (often ADR-0030 reboot); retrying SSH ...
```

Deploy’s IHP wait retries on any SSH exit 255, so a known_hosts mismatch can look like the ADR-0030 reboot race.

## Cause

`environments/<slug>/.ssh/known_hosts` still binds the Reserved IP (+ Stack SSH port) to an old Host’s keys. The IP survived; Host identity did not (Park→Apply before ADR-0046 forget, Host replace without Park, or interrupted cleanup). `StrictHostKeyChecking=accept-new` accepts **new** hosts only — it does not replace a mismatch.

## Mitigate

Do **not** Park a live Host just to clear TOFU. Do **not** set `StrictHostKeyChecking=no` or point Host-session at `~/.ssh/known_hosts`.

1. Drop the stale Environment store (safe local file; gitignored):

```bash
rm -f "environments/<slug>/.ssh/known_hosts" "environments/<slug>/.ssh/known_hosts.old"
```

If the Stack is already **Parked** and you prefer the operator path: `./park.sh --env <slug>` (already-Parked early exit also forgets — ADR-0046).

2. Retry `./deploy.sh --env <slug>` or `./ssh.sh --env <slug>`. First successful connect records the new key via `accept-new`.

If you distrust the Host (unexpected recreate), verify the new fingerprint out of band before retrying.

## Prevention

- **Park** forgets the Reserved IP’s entries after Park and on already-Parked (ADR-0046).
- **Teardown** resets the whole Environment store (Reserved IP gone).
- Host replace without Park still leaves a stale binding — use this runbook.
