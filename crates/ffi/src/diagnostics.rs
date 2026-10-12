//! Routes core diagnostics to a shell-registered sink (ADR-0045).
//! Metadata only: never ink, a chip, or key material.

use std::ffi::{CString, c_char, c_int};
use std::fmt;
use std::sync::{Mutex, Once, PoisonError};

/// How much attention a line wants.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Level {
    Notice = 0,
    /// A refusal with a consequence for the session.
    Fault = 1,
}

/// The C signature a shell registers. `message` is NUL-terminated UTF-8,
/// borrowed for the call only; it may arrive on any thread.
pub type CompanionDiagnosticSink = extern "C" fn(level: c_int, message: *const c_char);

/// The registered sink, or `None` for stderr.
static SINK: Mutex<Option<CompanionDiagnosticSink>> = Mutex::new(None);

static CREDENTIALS_BRIDGE: Once = Once::new();

/// Send every core diagnostic to `sink`, or NULL for stderr. Register
/// before the first restore; a second call replaces the first. The sink
/// must be thread-safe and should not call back into the core.
#[unsafe(no_mangle)]
pub extern "C" fn companion_set_diagnostic_sink(sink: Option<CompanionDiagnosticSink>) {
    *SINK.lock().unwrap_or_else(PoisonError::into_inner) = sink;

    // The credentials crate cannot depend on this one; bridge its notices.
    CREDENTIALS_BRIDGE.call_once(|| {
        companion_credentials::set_diagnostic_sink(|line: &str| {
            emit(Level::Notice, format_args!("{line}"));
        });
    });
}

pub(crate) fn emit(level: Level, args: fmt::Arguments<'_>) {
    // Called with no lock held, so a re-entering sink cannot deadlock.
    let sink = *SINK.lock().unwrap_or_else(PoisonError::into_inner);

    let Some(sink) = sink else {
        eprintln!("{args}");
        return;
    };

    let line = format!("{args}").replace('\0', " ");
    if let Ok(message) = CString::new(line) {
        sink(level as c_int, message.as_ptr());
    }
}

/// `eprintln!` for a [`Level::Fault`], routed to the sink.
macro_rules! diag_fault {
    ($($arg:tt)*) => {
        $crate::diagnostics::emit($crate::diagnostics::Level::Fault, format_args!($($arg)*))
    };
}

pub(crate) use diag_fault;

#[cfg(test)]
mod tests {
    use super::{CompanionDiagnosticSink, Level, companion_set_diagnostic_sink, emit};
    use std::ffi::{CStr, c_char, c_int};
    use std::sync::Mutex;

    static CAPTURED: Mutex<Vec<(c_int, String)>> = Mutex::new(Vec::new());

    /// The sink is process-wide; tests that install one take turns.
    static INSTALLING: Mutex<()> = Mutex::new(());

    extern "C" fn capture(level: c_int, message: *const c_char) {
        // SAFETY: `emit` passes a live NUL-terminated CString.
        let text = unsafe { CStr::from_ptr(message) }
            .to_string_lossy()
            .into_owned();
        CAPTURED
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push((level, text));
    }

    fn captured_lines() -> Vec<(c_int, String)> {
        CAPTURED
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    #[test]
    fn a_registered_sink_takes_the_line_and_stops_taking_it_when_cleared() {
        let _installing = INSTALLING
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);

        // Markers: other tests' lines land in the same collector.
        let routed = "diagnostics-test-routed-marker";
        let dropped = "diagnostics-test-dropped-marker";

        let sink: CompanionDiagnosticSink = capture;
        companion_set_diagnostic_sink(Some(sink));
        emit(Level::Fault, format_args!("{routed}"));
        emit(Level::Notice, format_args!("{routed} again"));
        companion_set_diagnostic_sink(None);
        emit(Level::Fault, format_args!("{dropped}"));

        let lines = captured_lines();
        assert!(
            lines
                .iter()
                .any(|(level, text)| *level == Level::Fault as c_int && text == routed),
            "the fault reached the sink at its own level: {lines:?}"
        );
        assert!(
            lines
                .iter()
                .any(|(level, text)| *level == Level::Notice as c_int
                    && text == &format!("{routed} again")),
            "the notice reached the sink at its own level: {lines:?}"
        );
        assert!(
            !lines.iter().any(|(_, text)| text.contains(dropped)),
            "a cleared sink takes nothing further: {lines:?}"
        );
    }

    #[test]
    fn a_message_carrying_a_nul_arrives_whole() {
        let _installing = INSTALLING
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);

        let marker = "diagnostics-test-nul-marker";
        let sink: CompanionDiagnosticSink = capture;
        companion_set_diagnostic_sink(Some(sink));
        emit(Level::Fault, format_args!("{marker} before\0after"));
        companion_set_diagnostic_sink(None);

        let lines = captured_lines();
        assert!(
            lines
                .iter()
                .any(|(_, text)| text == &format!("{marker} before after")),
            "the consequence half of the line survives the NUL: {lines:?}"
        );
    }
}
