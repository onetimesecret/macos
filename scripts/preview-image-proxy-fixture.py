#!/usr/bin/env python3
"""One-connection loopback proxy for opt-in PreviewImageNetworkTests."""

import json
from pathlib import Path
import select
import socket
import ssl
import sys


mode, folder = sys.argv[1], Path(sys.argv[2])
report = {"mode": mode}
try:
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(20)
        (folder / "port").write_text(str(listener.getsockname()[1]))
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(20)
            headers = b""
            while not headers.endswith(b"\r\n\r\n") and len(headers) < 16_384:
                value = connection.recv(1)
                if not value:
                    raise RuntimeError("closed before CONNECT")
                headers += value
            report["connect"] = headers.decode("ascii")
            if mode == "authentication":
                connection.sendall(
                    b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                    b'Proxy-Authenticate: Basic realm="preview-fixture"\r\n'
                    b"Content-Length: 0\r\nConnection: close\r\n\r\n"
                )
            elif mode == "untrustedTLS":
                connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(folder / "cert.pem", folder / "key.pem")
                try:
                    with context.wrap_socket(connection, server_side=True) as tls:
                        report["http_after_tls"] = bool(tls.recv(4_096))
                except ssl.SSLError:
                    report["tls_rejected"] = True
            elif mode == "tunnel":
                expected = "CONNECT raw.githubusercontent.com:443 HTTP/1.1\r\n"
                if not report["connect"].startswith(expected):
                    raise RuntimeError("unexpected tunnel target")
                with socket.create_connection(("raw.githubusercontent.com", 443), timeout=15) as upstream:
                    connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    report["tunneled_bytes"] = 0
                    active = True
                    while active:
                        ready, _, _ = select.select([connection, upstream], [], [], 20)
                        if not ready:
                            break
                        for source in ready:
                            try:
                                data = source.recv(65_536)
                            except ConnectionError:
                                active = False
                                break
                            if not data:
                                active = False
                                break
                            target = upstream if source is connection else connection
                            try:
                                target.sendall(data)
                            except ConnectionError:
                                active = False
                                break
                            report["tunneled_bytes"] += len(data)
            else:
                raise ValueError(mode)
except Exception as error:
    report["error"] = str(error)
finally:
    (folder / "report.json").write_text(json.dumps(report))
