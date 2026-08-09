#!/usr/bin/env python3
"""Host-local TCP proxy into database-postgres netns (ADR-0049 / #192).

Rootless service-network addresses are not reachable from Host root. This
listens on 127.0.0.1 and, for each connection, forks, setns()'s into the
Postgres container network namespace, and dials 127.0.0.1:5432 there.

Usage: database-console-host-proxy.py <netns-pid> <listen-port> <pidfile>
"""
from __future__ import annotations

import ctypes
import os
import select
import signal
import socket
import sys

CLONE_NEWNET = 0x40000000


def _setns_net(netns_pid: str) -> None:
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    ns_fd = os.open(f"/proc/{netns_pid}/ns/net", os.O_RDONLY)
    try:
        if libc.setns(ns_fd, CLONE_NEWNET) != 0:
            err = ctypes.get_errno()
            raise OSError(err, f"setns failed: {os.strerror(err)}")
    finally:
        os.close(ns_fd)


def _relay(a: socket.socket, b: socket.socket) -> None:
    sockets = [a, b]
    try:
        while True:
            readable, _, errored = select.select(sockets, [], sockets)
            if errored:
                break
            for src in readable:
                dst = b if src is a else a
                try:
                    data = src.recv(65536)
                except OSError:
                    return
                if not data:
                    return
                try:
                    dst.sendall(data)
                except OSError:
                    return
    finally:
        for s in sockets:
            try:
                s.close()
            except OSError:
                pass


def _child(conn: socket.socket, netns_pid: str) -> None:
    try:
        _setns_net(netns_pid)
        upstream = socket.create_connection(("127.0.0.1", 5432))
        _relay(conn, upstream)
    except Exception:
        try:
            conn.close()
        except OSError:
            pass
        os._exit(1)
    os._exit(0)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: database-console-host-proxy.py <netns-pid> <listen-port> <pidfile>"
        )
    netns_pid = sys.argv[1]
    listen_port = int(sys.argv[2])
    pidfile = sys.argv[3]

    # Reap proxy children so Accept doesn't accumulate zombies.
    signal.signal(signal.SIGCHLD, lambda *_: os.waitpid(-1, os.WNOHANG))

    with open(pidfile, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", listen_port))
    srv.listen(32)
    while True:
        conn, _ = srv.accept()
        pid = os.fork()
        if pid == 0:
            srv.close()
            _child(conn, netns_pid)
        conn.close()


if __name__ == "__main__":
    main()
