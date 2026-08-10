# Reading the Platform journal

ADR-0050. Use this when you need diagnostic output from a Propraetor-owned Platform User unit (Component, Fabric-adjacent container, Workload Quadlet, or authored `systemd/` oneshot/timer) on a public Host.

**Not** Host diagnostics (file/command bundles such as IHP cloud-init). **Not** SSH Setup / Deploy session output.

## Access the Host

```bash
./ssh.sh --env <slug>
```

You land as **root**. Platform User units are rootless — always query the **platform** user journal with that user’s session environment.

## Platform User session env

```bash
UID_NUM="$(id -u platform)"
export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
```

Or one-shot via `runuser`:

```bash
UID_NUM="$(id -u platform)"
runuser -u platform -- env \
  XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
  journalctl --user -u <unit> -n 100 --no-pager
```

## Component / unit examples

Quadlet-generated names follow the unit file basename (e.g. `edge-nginx.container` → `edge-nginx.service`; pod units similarly). Native units under `systemd/` keep their names (`edge-acme.service`, `edge-acme.timer`).

```bash
# Edge nginx container
runuser -u platform -- env XDG_RUNTIME_DIR="/run/user/$(id -u platform)" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u platform)/bus" \
  journalctl --user -u edge-nginx.service -f

# Edge ACME oneshot (last run)
runuser -u platform -- env XDG_RUNTIME_DIR="/run/user/$(id -u platform)" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u platform)/bus" \
  journalctl --user -u edge-acme.service -n 200 --no-pager

# Database Postgres container
runuser -u platform -- env XDG_RUNTIME_DIR="/run/user/$(id -u platform)" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u platform)/bus" \
  journalctl --user -u database-postgres.service -n 100 --no-pager
```

List Platform User units if the name is unclear:

```bash
runuser -u platform -- env XDG_RUNTIME_DIR="/run/user/$(id -u platform)" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u platform)/bus" \
  systemctl --user list-units --type=service --all
```

## Workload units

Workload Quadlets and `systemd/` units install under the same Platform User. Unit basenames come from the Workload tree (`quadlets/*.container`, `systemd/*.service`, …).

```bash
# Replace <unit> with the installed unit name, e.g. myapp.service
runuser -u platform -- env XDG_RUNTIME_DIR="/run/user/$(id -u platform)" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u platform)/bus" \
  journalctl --user -u <unit> -n 100 --no-pager
```

For a pod-centric Workload, prefer the **pod** unit (and members started with the pod) over assuming every `.container` has an independently useful journal filter.

## `podman logs` vs `journalctl`

With Platform journal capture, `journalctl --user -u <unit>` is the primary operator path. `podman logs` may work when the journald driver and user journal readback are healthy; if it is empty while the unit is running, prefer `journalctl --user` before assuming the process is silent.

## Access / request logs

Diagnostic streams are required on stdout/stderr. **Access/request logs default off** (e.g. Edge `access_log off`) so high-QPS fronts do not fill the persistent journal. Enabling them is an explicit opt-in and will consume the Host journal budget faster (IHP sets size caps under ADR-0050).
