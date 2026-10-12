//! Process-wide hardening that must run before any secret is held.

use std::sync::Once;

static HARDEN: Once = Once::new();

/// Disables core dumps for the process. Idempotent.
pub fn harden_process() {
    HARDEN.call_once(disable_core_dumps);
}

#[cfg(unix)]
#[allow(unsafe_code)]
fn disable_core_dumps() {
    // SAFETY: a valid resource id and a pointer to a live, initialised
    // `rlimit`. The result is ignored: this hardening is best-effort.
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    #[allow(unsafe_code)]
    fn hardening_leaves_no_core_dump_allowance_and_runs_twice_harmlessly() {
        harden_process();
        harden_process();
        let mut lim = libc::rlimit {
            rlim_cur: 1,
            rlim_max: 1,
        };
        // SAFETY: a valid resource id and a pointer to a live `rlimit`.
        assert_eq!(
            unsafe { libc::getrlimit(libc::RLIMIT_CORE, &raw mut lim) },
            0
        );
        assert_eq!((lim.rlim_cur, lim.rlim_max), (0, 0));
    }
}
