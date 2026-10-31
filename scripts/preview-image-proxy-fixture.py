#!/usr/bin/env python3
"""One-connection loopback proxy for opt-in PreviewImageNetworkTests."""

import json
from pathlib import Path
import select
import signal
import socket
import ssl
import sys


SOCKET_TIMEOUT = 5
TUNNEL_IDLE_TIMEOUT = 2
mode, folder = sys.argv[1], Path(sys.argv[2])
report = {"mode": mode, "phase": "starting"}
exit_code = 0


def publish(name, text):
    temporary = folder / (name + ".tmp")
    temporary.write_text(text)
    temporary.replace(folder / name)


def terminated(signum, _frame):
    raise RuntimeError(f"fixture received signal {signum}")


signal.signal(signal.SIGTERM, terminated)
try:
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(SOCKET_TIMEOUT)
        report["phase"] = "accepting"
        publish("port", str(listener.getsockname()[1]))
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(SOCKET_TIMEOUT)
            report["phase"] = "reading CONNECT"
            headers = b""
            while not headers.endswith(b"\r\n\r\n") and len(headers) < 16_384:
                value = connection.recv(1)
                if not value:
                    raise RuntimeError("closed before CONNECT")
                headers += value
            if not headers.endswith(b"\r\n\r\n"):
                raise RuntimeError("CONNECT headers exceed limit")
            report["connect"] = headers.decode("ascii")
            if mode == "authentication":
                report["phase"] = "sending authentication refusal"
                connection.sendall(
                    b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                    b'Proxy-Authenticate: Basic realm="preview-fixture"\r\n'
                    b"Content-Length: 0\r\nConnection: close\r\n\r\n"
                )
            elif mode == "untrustedTLS":
                connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(folder / "cert.pem", folder / "key.pem")
                report["phase"] = "untrusted TLS handshake"
                try:
                    tls = context.wrap_socket(connection, server_side=True)
                except (ssl.SSLError, ConnectionResetError) as error:
                    report["tls_rejected"] = True
                    report["tls_error"] = str(error)
                else:
                    with tls:
                        report["http_after_tls"] = bool(tls.recv(4_096))
            elif mode == "tunnel":
                expected = "CONNECT raw.githubusercontent.com:443 HTTP/1.1\r\n"
                if not report["connect"].startswith(expected):
                    raise RuntimeError("unexpected tunnel target")
                report["phase"] = "connecting upstream"
                with socket.create_connection(("raw.githubusercontent.com", 443), timeout=SOCKET_TIMEOUT) as upstream:
                    connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    report["phase"] = "tunneling"
                    report["tunneled_bytes"] = 0
                    active = True
                    while active:
                        ready, _, _ = select.select([connection, upstream], [], [], TUNNEL_IDLE_TIMEOUT)
                        if not ready:
                            report["tunnel_end"] = "idle timeout"
                            break
                        for source in ready:
                            try:
                                data = source.recv(65_536)
                            except ConnectionError as error:
                                report["tunnel_end"] = str(error)
                                active = False
                                break
                            if not data:
                                report["tunnel_end"] = "peer closed"
                                active = False
                                break
                            target = upstream if source is connection else connection
                            try:
                                target.sendall(data)
                            except ConnectionError as error:
                                report["tunnel_end"] = str(error)
                                active = False
                                break
                            report["tunneled_bytes"] += len(data)
            else:
                raise ValueError(mode)
        report["phase"] = "finished"
except Exception as error:
    exit_code = 1
    report["error"] = f"{type(error).__name__}: {error}"
finally:
    publish("report.json", json.dumps(report))
sys.exit(exit_code)
