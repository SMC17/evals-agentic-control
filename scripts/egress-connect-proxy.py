#!/usr/bin/env python3
"""
egress-connect-proxy.py — minimal HTTP CONNECT proxy with a hostname allowlist.

Listens on a UNIX domain socket. Each connection is treated as a single HTTP
CONNECT request:

    CONNECT api.anthropic.com:443 HTTP/1.1
    Host: api.anthropic.com:443
    <crlf>

If the target host:port matches an entry in the allowlist (default:
api.anthropic.com:443), the proxy resolves the host, opens a TCP connection
to it, replies "HTTP/1.1 200 Connection Established\\r\\n\\r\\n", and pumps
bytes both ways until either side closes. The client then performs a TLS
handshake END-TO-END with the real upstream — the proxy never decrypts.

If the target is NOT in the allowlist, the proxy replies
"HTTP/1.1 403 Forbidden by sandbox egress filter\\r\\n\\r\\n" and closes.
Forbidden attempts are logged.

This is Approach A from docs/EGRESS_FILTER_DESIGN.md. It is intentionally
small (<200 lines) so it can be audited by hand.

Non-claims:
  - The proxy DOES NOT MITM TLS. It cannot inspect HTTPS bodies. The
    allowlist is by hostname only, not by URL path or HTTP method.
  - The proxy trusts the CONNECT line's hostname string. A client that
    sends "CONNECT api.anthropic.com:443" but then performs TLS SNI for a
    different host CAN reach an attacker-controlled cert at the resolved
    Anthropic IP. This is a limit of CONNECT-style allowlisting in general.
  - The proxy resolves the hostname via the host's normal DNS (whatever
    resolv.conf and nsswitch.conf say). It does NOT pin to a specific IP.
    DNS substitution attacks against the host resolver are out of scope.
  - One CONNECT per TCP connection. No keep-alive, no HTTP/2.
  - The allowlist is loaded once at startup. To change it, restart.

Usage:
  egress-connect-proxy.py --socket /path/to/proxy.sock
                          [--allow api.anthropic.com:443]
                          [--log /path/to/proxy.log]
"""

import argparse
import os
import socket
import sys
import threading
import time
import signal
from datetime import datetime, timezone


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")[:-4] + "Z"


def log(handle, msg: str) -> None:
    line = f"[{ts()}] {msg}\n"
    try:
        handle.write(line)
        handle.flush()
    except Exception:
        pass
    sys.stderr.write(line)


def pump(src: socket.socket, dst: socket.socket, label: str, logh) -> None:
    """Forward bytes from src to dst until either side closes."""
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def read_request_line_and_headers(sock: socket.socket, timeout: float = 5.0) -> bytes:
    """Read until \\r\\n\\r\\n or timeout/error. Returns raw bytes."""
    sock.settimeout(timeout)
    buf = b""
    while b"\r\n\r\n" not in buf:
        try:
            data = sock.recv(4096)
        except socket.timeout:
            break
        if not data:
            break
        buf += data
        if len(buf) > 16384:
            break
    sock.settimeout(None)
    return buf


def handle_one(client: socket.socket, allowlist: set, logh) -> None:
    peer = "uds-peer"
    try:
        raw = read_request_line_and_headers(client)
        if not raw:
            log(logh, f"{peer}: empty request, closing")
            return
        first_line = raw.split(b"\r\n", 1)[0].decode("latin-1", errors="replace")
        parts = first_line.split(" ")
        if len(parts) < 3 or parts[0].upper() != "CONNECT":
            log(logh, f"{peer}: not a CONNECT request: {first_line!r}")
            try:
                client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
            return

        target = parts[1].strip()
        if target not in allowlist:
            log(logh, f"BLOCK CONNECT {target!r} (not in allowlist)")
            try:
                client.sendall(
                    b"HTTP/1.1 403 Forbidden by sandbox egress filter\r\n"
                    b"Content-Length: 0\r\n"
                    b"\r\n"
                )
            except OSError:
                pass
            return

        # Parse host:port
        if ":" in target:
            host, port_s = target.rsplit(":", 1)
            port = int(port_s)
        else:
            host = target
            port = 443

        log(logh, f"ALLOW CONNECT {target} — resolving and dialing")

        # Resolve and dial. We let the OS pick AF (IPv4/IPv6).
        upstream = None
        last_err = None
        for af, socktype, proto, _, sa in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM):
            try:
                upstream = socket.socket(af, socktype, proto)
                upstream.settimeout(10.0)
                upstream.connect(sa)
                upstream.settimeout(None)
                break
            except OSError as e:
                last_err = e
                if upstream is not None:
                    try:
                        upstream.close()
                    except OSError:
                        pass
                upstream = None
        if upstream is None:
            log(logh, f"DIAL_FAIL {target}: {last_err!r}")
            try:
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
            return

        # 200, then pump.
        try:
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        except OSError as e:
            log(logh, f"CLIENT_WRITE_FAIL {target}: {e!r}")
            upstream.close()
            return

        log(logh, f"PUMP_START {target}")
        t1 = threading.Thread(target=pump, args=(client, upstream, "c->u", logh), daemon=True)
        t2 = threading.Thread(target=pump, args=(upstream, client, "u->c", logh), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        log(logh, f"PUMP_END {target}")
        try:
            upstream.close()
        except OSError:
            pass
    except Exception as e:
        log(logh, f"handle_one exception: {e!r}")
    finally:
        try:
            client.close()
        except OSError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True, help="UNIX socket path to listen on")
    ap.add_argument(
        "--allow",
        action="append",
        default=None,
        help="host:port to allow; may be repeated; default: api.anthropic.com:443",
    )
    ap.add_argument("--log", default=None, help="proxy log path; default stderr only")
    ap.add_argument("--pidfile", default=None, help="write our PID here for the supervisor")
    args = ap.parse_args()

    allowlist = set(args.allow or ["api.anthropic.com:443"])

    # Open log handle (line-buffered).
    if args.log:
        logh = open(args.log, "a", buffering=1)
    else:
        logh = open(os.devnull, "w")

    # Remove stale socket.
    sock_path = args.socket
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    os.chmod(sock_path, 0o600)
    srv.listen(64)

    if args.pidfile:
        with open(args.pidfile, "w") as fh:
            fh.write(str(os.getpid()))

    log(logh, f"egress-connect-proxy listening on {sock_path}, allow={sorted(allowlist)}")

    # Clean shutdown on SIGTERM/SIGINT.
    def _shutdown(_sig, _frm):
        log(logh, "received shutdown signal")
        try:
            srv.close()
        except OSError:
            pass
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    while True:
        try:
            client, _addr = srv.accept()
        except OSError:
            break
        t = threading.Thread(target=handle_one, args=(client, allowlist, logh), daemon=True)
        t.start()
    return 0


if __name__ == "__main__":
    sys.exit(main())
