//! The loopback redirect target of RFC 8252 §7.3: one listener, on the
//! local interface, for the seconds the ceremony takes. This is not a
//! server side and not the outbound network boundary — it accepts one
//! connection from the machine's own browser and closes.

use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, TcpListener};
use std::time::Duration;

/// A listener bound to an ephemeral loopback port, alive for exactly
/// one redirect.
pub struct OneShotListener {
    listener: TcpListener,
}

/// What the browser is shown once the redirect has landed; the ceremony
/// continues in the app, so the page's one job is to say "go back".
const ANSWER_PAGE: &str = "<!doctype html><meta charset=\"utf-8\">\
<title>Onetime Secret</title><p>Signed in. You can close this tab and \
return to the app.</p>";

impl OneShotListener {
    /// Bind an ephemeral port on `127.0.0.1`. `None` when the bind
    /// fails, which the caller surfaces as the ceremony not starting.
    #[must_use]
    pub fn bind() -> Option<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).ok()?;
        Some(Self { listener })
    }

    /// The port the OS granted, for [`crate::oauth::AuthCeremony::begin`]'s
    /// exact-match redirect URI.
    #[must_use]
    pub fn port(&self) -> u16 {
        self.listener.local_addr().map(|a| a.port()).unwrap_or(0)
    }

    /// Accept one connection, answer it, and return the redirect's raw
    /// query string (the part after `?`). Blocks up to `patience` — the
    /// user is in a browser consent screen, so minutes, not seconds —
    /// then gives up with `None`, which abandons the ceremony. The
    /// listener is consumed either way: one redirect, then gone.
    #[must_use]
    pub fn accept_redirect(self, patience: Duration) -> Option<String> {
        self.listener.set_nonblocking(false).ok()?;
        // Bound the whole exchange: accept has no native timeout, so
        // poll with the read timeout carrying the budget once a
        // connection lands.
        let deadline = std::time::Instant::now() + patience;
        self.listener.set_nonblocking(true).ok()?;
        let (mut stream, _) = loop {
            match self.listener.accept() {
                Ok(pair) => break pair,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    if std::time::Instant::now() >= deadline {
                        return None;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(_) => return None,
            }
        };
        stream.set_nonblocking(false).ok()?;
        stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
        // The request line is all that matters; read until its end.
        let mut buffer = Vec::with_capacity(1024);
        let mut chunk = [0u8; 512];
        while !buffer.windows(2).any(|w| w == b"\r\n") && buffer.len() < 8192 {
            let n = stream.read(&mut chunk).ok()?;
            if n == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..n]);
        }
        let request_line = std::str::from_utf8(&buffer)
            .ok()?
            .lines()
            .next()?
            .to_owned();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{ANSWER_PAGE}",
            ANSWER_PAGE.len(),
        );
        let _ = stream.write_all(response.as_bytes());
        // GET /callback?code=…&state=… HTTP/1.1
        let target = request_line.split_whitespace().nth(1)?;
        let (path, query) = target.split_once('?')?;
        (path == "/callback").then(|| query.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use std::net::TcpStream;

    use super::*;

    #[test]
    fn hands_back_the_callback_query_and_answers_the_browser() {
        let listener = OneShotListener::bind().unwrap();
        let port = listener.port();
        assert_ne!(port, 0);
        let browser = std::thread::spawn(move || {
            let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            stream
                .write_all(b"GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: x\r\n\r\n")
                .unwrap();
            let mut answer = String::new();
            let _ = stream.read_to_string(&mut answer);
            answer
        });
        let query = listener.accept_redirect(Duration::from_secs(5)).unwrap();
        assert_eq!(query, "code=abc&state=xyz");
        let answer = browser.join().unwrap();
        assert!(answer.starts_with("HTTP/1.1 200"));
        assert!(answer.contains("close this tab"));
    }

    #[test]
    fn a_redirect_to_the_wrong_path_is_refused() {
        let listener = OneShotListener::bind().unwrap();
        let port = listener.port();
        let browser = std::thread::spawn(move || {
            let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            stream
                .write_all(b"GET /elsewhere?code=abc HTTP/1.1\r\n\r\n")
                .unwrap();
            let mut sink = String::new();
            let _ = stream.read_to_string(&mut sink);
        });
        assert!(listener.accept_redirect(Duration::from_secs(5)).is_none());
        browser.join().unwrap();
    }
}
