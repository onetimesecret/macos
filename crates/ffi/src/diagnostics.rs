//! Where a core diagnostic goes.
//!
//! The core's refusals are written for whoever is trying to work out
//! why an app stopped remembering: which step said no, and what that
//! costs the session. They were on stderr, and stderr is where a
//! double clicked app's output ends: `launchd` hands the process
//! `/dev/null`, so every line the core wrote for that reader was
//! discarded before anyone could read it. Seeing them meant running
//! `/Applications/OnetimePad.app/Contents/MacOS/OnetimePad` from a
//! terminal, which is exactly the run that reproduces nothing, because
//! a terminal launch has a different keychain posture, a different
//! signature check, and a different environment from the launch that
//! failed.
//!
//! So the destination is the shell's, not the core's. The shell
//! registers one C function through [`companion_set_diagnostic_sink`]
//! and forwards each line to the unified log, beside the persistence
//! trail it already keeps, where `log show` reaches it after the fact
//! and without the app being run any particular way. With no sink
//! registered the lines still go to stderr, so a `cargo test` run and a
//! terminal launch read as they always did.
//!
//! What crosses here is metadata: which step refused, and the backend's
//! own error text. Never ink, never a chip, never key material. The
//! rule is the same one the FFI seam keeps everywhere else, and it is
//! worth restating in the one module whose whole job is to send strings
//! out of the process.

use std::ffi::{CString, c_char, c_int};
use std::fmt;
use std::sync::{Mutex, Once, PoisonError};

/// How much attention a line wants. Two levels, because the shell has
/// exactly two things to do with one: file it (`notice`) or surface it
/// as a failure in the log (`error`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Level {
    /// Something worth knowing that is not a failure: a build running
    /// on the fallback keychain tier, say, which is ordinary for a dev
    /// build and load bearing when reading a bug report from one.
    Notice = 0,
    /// A refusal with a consequence for the session: a key half that
    /// would not load, a file that would not authenticate, a rotation
    /// the keychain refused.
    Fault = 1,
}

/// The C signature a shell registers. `message` is NUL terminated UTF-8
/// and **borrowed for the duration of the call only**: copy what you
/// keep. It may arrive on any thread the core runs on.
pub type CompanionDiagnosticSink = extern "C" fn(level: c_int, message: *const c_char);

/// The registered sink, or `None` for the stderr default. A plain
/// function pointer rather than a closure, because the value has to
/// survive being handed across the ABI, and because copying it out of
/// the lock (below) is then free.
static SINK: Mutex<Option<CompanionDiagnosticSink>> = Mutex::new(None);

/// Bridges the credentials crate's own notices into this sink, once.
static CREDENTIALS_BRIDGE: Once = Once::new();

/// Send every core diagnostic to `sink` instead of stderr, or pass NULL
/// to put them back on stderr.
///
/// Register once, early, before the first call that could refuse
/// anything: the restore path runs at first reveal and its refusals are
/// the ones worth having. Registering later loses whatever was already
/// written, and registering twice simply replaces the destination.
///
/// The sink must be safe to call from any thread and must not call back
/// into the core: the pointer is copied out from under the lock before
/// the call, so re-entering cannot deadlock, but a shell that re-enters
/// is a shell reasoning about core state from inside a log line.
///
/// # Safety
///
/// The pointer handed to the sink is valid only for that call. Nothing
/// is retained on the Rust side.
#[unsafe(no_mangle)]
pub extern "C" fn companion_set_diagnostic_sink(sink: Option<CompanionDiagnosticSink>) {
    *SINK.lock().unwrap_or_else(PoisonError::into_inner) = sink;

    // The credentials crate announces its own keychain tier degradation
    // and cannot depend on this crate to do it, so it carries a sink of
    // the same shape. Point it here the first time a shell asks for
    // diagnostics, so one registration covers both. Left installed if
    // the shell later clears the sink: `emit` falls back to stderr, and
    // the notice with it.
    CREDENTIALS_BRIDGE.call_once(|| {
        companion_credentials::set_diagnostic_sink(|line: &str| {
            emit(Level::Notice, format_args!("{line}"));
        });
    });
}

/// One line out: to the registered sink, or to stderr.
pub(crate) fn emit(level: Level, args: fmt::Arguments<'_>) {
    // Copied out, then the guard drops: the sink is called with no lock
    // held, so a sink that logs from several threads (every shell) and
    // one that re-enters (no shell should) both stay live.
    let sink = *SINK.lock().unwrap_or_else(PoisonError::into_inner);

    let Some(sink) = sink else {
        eprintln!("{args}");
        return;
    };

    // A NUL inside the message would truncate it at the ABI, and the
    // interesting half of these lines is the end: the consequence. The
    // only untrusted text here is a backend error string, which has no
    // business carrying one, so this is a guard rather than a case.
    let line = format!("{args}").replace('\0', " ");
    if let Ok(message) = CString::new(line) {
        sink(level as c_int, message.as_ptr());
    }
}

/// A refusal with a consequence: `diag_fault!("...")`, spelled like
/// `eprintln!`, routed wherever the shell asked for.
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

    /// What the test sink saw. A `static`, because the sink crosses the
    /// ABI as a bare function pointer and so can capture nothing.
    static CAPTURED: Mutex<Vec<(c_int, String)>> = Mutex::new(Vec::new());

    /// Serialises the tests that install a sink: the sink is process
    /// wide, so two of them running at once would each clear the
    /// other's.
    static INSTALLING: Mutex<()> = Mutex::new(());

    extern "C" fn capture(level: c_int, message: *const c_char) {
        // Safety: the contract this module documents, held by the
        // caller directly above.
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

        // Markers rather than exact contents: any other test in this
        // crate that refuses something lands in the same collector
        // while the sink is installed, and that is the sink working.
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
