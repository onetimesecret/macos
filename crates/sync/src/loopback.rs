//! The loopback redirect target of RFC 8252 §7.3: one listener, on the
//! local interface, for the seconds the ceremony takes. This is not a
//! server side and not the outbound network boundary — it accepts one
//! connection from the machine's own browser and closes.

use std::io::{Read as _, Write as _};
use std::net::{Ipv4Addr, TcpListener};
use std::sync::atomic::{AtomicBool, Ordering};
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

    /// Accept connections until the redirect lands, answer it, and
    /// return the redirect's raw query string (the part after `?`).
    /// Blocks up to `patience` — the user is in a browser consent
    /// screen, so minutes, not seconds — then gives up with `None`,
    /// which abandons the ceremony. A stray connection meanwhile (a
    /// speculative preflight, a favicon probe, a port scan finding
    /// the ephemeral port) is answered `404` and does not consume the
    /// ceremony: only the `/callback` redirect or the deadline ends
    /// the wait. The listener is consumed either way: one redirect,
    /// then gone.
    ///
    /// `abandoned` is the user's own way out. Five minutes is the
    /// right patience for someone reading a consent screen and the
    /// wrong one for someone who closed the tab and came back to the
    /// app, so the wait is watched: a caller that sets the flag ends
    /// it within one poll, and the ceremony reports itself abandoned
    /// exactly as a lapsed deadline would. Without this the surface
    /// could offer a button that stopped nothing, which is worse than
    /// offering none (ADR-0027 §5, `signing_in`).
    #[must_use]
    pub fn accept_redirect(self, patience: Duration, abandoned: &AtomicBool) -> Option<String> {
        let deadline = std::time::Instant::now() + patience;
        self.listener.set_nonblocking(true).ok()?;
        loop {
            if abandoned.load(Ordering::Relaxed) {
                return None;
            }
            let mut stream = match self.listener.accept() {
                Ok((stream, _)) => stream,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    if std::time::Instant::now() >= deadline {
                        return None;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                    continue;
                }
                Err(_) => return None,
            };
            if let Some(query) = Self::serve(&mut stream) {
                return Some(query);
            }
            if std::time::Instant::now() >= deadline {
                return None;
            }
        }
    }

    /// Answer one connection: the callback's query when this is the
    /// redirect, `None` — after a `404` — for anything else.
    fn serve(stream: &mut std::net::TcpStream) -> Option<String> {
        if stream.set_nonblocking(false).is_err()
            || stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .is_err()
        {
            return None;
        }
        // The request line is all that matters; read until its end.
        let mut buffer = Vec::with_capacity(1024);
        let mut chunk = [0u8; 512];
        while !buffer.windows(2).any(|w| w == b"\r\n") && buffer.len() < 8192 {
            let Ok(n) = stream.read(&mut chunk) else {
                break;
            };
            if n == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..n]);
        }
        // GET /callback?code=…&state=… HTTP/1.1
        let query = std::str::from_utf8(&buffer)
            .ok()
            .and_then(|text| text.lines().next())
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|target| target.split_once('?'))
            .and_then(|(path, query)| (path == "/callback").then(|| query.to_owned()));
        let response = if query.is_some() {
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{ANSWER_PAGE}",
                ANSWER_PAGE.len(),
            )
        } else {
            "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_owned()
        };
        let _ = stream.write_all(response.as_bytes());
        query
    }
}

#[cfg(test)]
mod tests {
    use std::net::TcpStream;
    use std::sync::Arc;

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
        let query = listener
            .accept_redirect(Duration::from_secs(5), &AtomicBool::new(false))
            .unwrap();
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
            sink
        });
        assert!(
            listener
                .accept_redirect(Duration::from_millis(300), &AtomicBool::new(false))
                .is_none()
        );
        let answer = browser.join().unwrap();
        assert!(answer.starts_with("HTTP/1.1 404"));
    }

    #[test]
    fn a_stray_connection_does_not_consume_the_ceremony() {
        let listener = OneShotListener::bind().unwrap();
        let port = listener.port();
        let browser = std::thread::spawn(move || {
            // A port scan lands first: connects, sends nothing the
            // ceremony recognizes, and goes away.
            let mut stray = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            stray
                .write_all(b"GET /favicon.ico HTTP/1.1\r\n\r\n")
                .unwrap();
            let mut sink = String::new();
            let _ = stray.read_to_string(&mut sink);
            // The real redirect follows and must still be served.
            let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            stream
                .write_all(b"GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: x\r\n\r\n")
                .unwrap();
            let mut answer = String::new();
            let _ = stream.read_to_string(&mut answer);
            answer
        });
        let query = listener
            .accept_redirect(Duration::from_secs(5), &AtomicBool::new(false))
            .unwrap();
        assert_eq!(query, "code=abc&state=xyz");
        let answer = browser.join().unwrap();
        assert!(answer.starts_with("HTTP/1.1 200"));
    }

    #[test]
    fn the_wait_ends_when_the_user_gives_up_on_it() {
        let listener = OneShotListener::bind().unwrap();
        let abandoned = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&abandoned);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(60));
            flag.store(true, Ordering::Relaxed);
        });
        let began = std::time::Instant::now();
        // A patience no test would sit through, so only the flag can
        // explain a prompt return.
        assert!(
            listener
                .accept_redirect(Duration::from_secs(300), &abandoned)
                .is_none()
        );
        assert!(
            began.elapsed() < Duration::from_secs(10),
            "giving up has to end the wait, not merely record a wish"
        );
    }

    #[test]
    fn a_wait_abandoned_before_it_starts_never_binds_the_browser() {
        let listener = OneShotListener::bind().unwrap();
        assert!(
            listener
                .accept_redirect(Duration::from_secs(300), &AtomicBool::new(true))
                .is_none()
        );
    }
}
