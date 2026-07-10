//! Process-wide hardening that must run before any secret is held.

use std::sync::Once;

static HARDEN: Once = Once::new();

/// Harden the process for holding secrets. Currently this disables core
/// dumps, so a crash cannot spill a locked page to disk — the companion
/// piece to [`crate::SecretBuffer`]'s `mlock` (doc 05 security posture).
///
/// Idempotent and cheap: the work runs exactly once no matter how many
/// times this is called, so shell init, FFI init, and individual tests
/// may all call it freely.
pub fn harden_process() {
    HARDEN.call_once(disable_core_dumps);
}

#[cfg(unix)]
#[allow(unsafe_code)]
fn disable_core_dumps() {
    // SAFETY: `setrlimit` with a valid resource id and a well-formed
    // `rlimit` (both fields zeroed) is a standard libc call. We pass a
    // stack-allocated value by const pointer and ignore the result:
    // failing to tighten the limit is best-effort hardening, never fatal.
    unsafe {
        let lim = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        let _ = libc::setrlimit(libc::RLIMIT_CORE, &lim);
    }
}

#[cfg(not(unix))]
fn disable_core_dumps() {}
