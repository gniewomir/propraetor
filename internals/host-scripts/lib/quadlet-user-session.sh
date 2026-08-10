#!/usr/bin/env bash
# Shared rootless Quadlet / native systemd user-session helpers for Component Setup.
# Sourced on the Host only (not an operator entrypoint).
# Requires: USER_NAME (Platform User login name)
# Exports: HOME_DIR, UID_NUM, UNIT_DIR, SYSTEMD_USER_DIR, XDG_RUNTIME_DIR,
#          DBUS_SESSION_BUS_ADDRESS
#
# quadlet_user_session_begin  — resolve paths; set Platform User XDG + session bus;
#                               ensure UNIT_DIR + SYSTEMD_USER_DIR exist
# quadlet_user_session_reload — start user@, wait XDG_RUNTIME_DIR, daemon-reload
# quadlet_user CMD...         — runuser as Platform User with Platform User session env
#
# Never inherit the caller's XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS (root SSH
# often has /run/user/0). Wrong XDG → systemctl --user "Operation not permitted";
# wrong DBUS → podman/crun cgroup "Permission denied" (e.g. nginx -t via exec).

quadlet_user_session_begin() {
  id "${USER_NAME}" >/dev/null
  HOME_DIR="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
  UID_NUM="$(id -u "${USER_NAME}")"
  UNIT_DIR="${HOME_DIR}/.config/containers/systemd"
  SYSTEMD_USER_DIR="${HOME_DIR}/.config/systemd/user"
  # Platform User runtime only — do not keep root (or other) session env.
  export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  mkdir -p "${UNIT_DIR}" "${SYSTEMD_USER_DIR}"
}

quadlet_user() {
  local runtime="/run/user/${UID_NUM:?quadlet_user: UID_NUM unset; call quadlet_user_session_begin first}"
  local home="${HOME_DIR:?quadlet_user: HOME_DIR unset; call quadlet_user_session_begin first}"
  # Root SSH cwd is /root; Podman as Platform User cannot retain that directory.
  (
    cd "${home}" || cd /
    exec runuser -u "${USER_NAME}" -- env \
      "XDG_RUNTIME_DIR=${runtime}" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=${runtime}/bus" \
      "$@"
  )
}

quadlet_user_session_reload() {
  systemctl start "user@${UID_NUM}.service"
  export XDG_RUNTIME_DIR="/run/user/${UID_NUM}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -d "${XDG_RUNTIME_DIR}" ]] && break
    sleep 0.5
  done
  quadlet_user systemctl --user daemon-reload
}
