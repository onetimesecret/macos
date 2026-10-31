"""Handshake reports distinguish peer aborts from fixture failures."""

import json
from pathlib import Path
import runpy
import ssl
import tempfile
import unittest
from unittest import mock


FIXTURE = Path(__file__).resolve().parents[1] / "preview-image-proxy-fixture.py"


class PreviewImageProxyFixtureTests(unittest.TestCase):
    def handshake_report(self, error):
        with tempfile.TemporaryDirectory(prefix="preview-handshake-test-") as temporary:
            folder = Path(temporary)
            connection = mock.MagicMock()
            connection.__enter__.return_value = connection
            headers = b"CONNECT preview-validation.example.com:443 HTTP/1.1\r\n\r\n"
            connection.recv.side_effect = [bytes([value]) for value in headers]
            listener = mock.MagicMock()
            listener.__enter__.return_value = listener
            listener.getsockname.return_value = ("127.0.0.1", 12345)
            listener.accept.return_value = (connection, ("127.0.0.1", 54321))
            context = mock.Mock()
            context.wrap_socket.side_effect = error
            with mock.patch("sys.argv", [str(FIXTURE), "untrustedTLS", temporary]), \
                 mock.patch("signal.signal"), \
                 mock.patch("socket.socket", return_value=listener), \
                 mock.patch("ssl.SSLContext", return_value=context), \
                 self.assertRaises(SystemExit) as exited:
                runpy.run_path(str(FIXTURE), run_name="__main__")
            return exited.exception.code, json.loads((folder / "report.json").read_text())

    def test_tls_alerts_and_peer_aborts_report_no_http(self):
        for error in [ssl.SSLError("certificate refused"), ConnectionResetError("reset"),
                      BrokenPipeError("broken pipe"), ConnectionAbortedError("aborted")]:
            with self.subTest(error=type(error).__name__):
                code, report = self.handshake_report(error)
                self.assertEqual(code, 0)
                self.assertIs(report.get("tls_rejected"), True)
                self.assertNotIn("http_after_tls", report)
                self.assertNotIn("error", report)

    def test_timeout_and_other_os_errors_remain_fixture_failures(self):
        for error in [TimeoutError("timed out"), OSError("fixture failure")]:
            with self.subTest(error=type(error).__name__):
                code, report = self.handshake_report(error)
                self.assertEqual(code, 1)
                self.assertIn(type(error).__name__, report["error"])
                self.assertNotIn("tls_rejected", report)


if __name__ == "__main__":
    unittest.main()
