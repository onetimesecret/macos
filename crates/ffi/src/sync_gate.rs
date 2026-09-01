//! The account gate as one value (ADR-0027 §5). ADR-0021 §3 gave the
//! account exactly one job, to say whether this client may attach to
//! the channel, and this module says where that answer stands.
//!
//! It exists because the shell used to infer the answer from refusal
//! strings scattered across attach, pump and sign-in, which is an
//! inference that can disagree with the core it is guessing about. One
//! value crosses the seam instead, and the words issue #102 shows are
//! chosen from a ladder the core reports rather than from a state the
//! surface reconstructed.
//!
//! Nothing here can disable the pad. The gate is read by the status
//! routes and by nothing else: creating, editing, sealing, concealing
//! and expiring a page never consult it, which is how
//! `docs/design-brief.md`'s "no account required to use the core loop"
//! stays structural rather than promised.

/// What the last attempt to use the account credential met. Held in
/// memory only: nothing durable records *why* a token is gone, and a
/// durable "you were refused" note would be a claim about the past
/// that a restored backup could falsify (ADR-0027 §5).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum GateFault {
    /// The account server said no: the grant is dead, the resting
    /// token has been deleted, and re-enrolment is the way back.
    Refused,
    /// Nobody answered, or the answer was the account server or the
    /// relay being unwell rather than saying no. The credential stands
    /// and the loop retries.
    Unreachable,
}

/// Where the client stands with the channel's account gate. Seven
/// states, each with its own sentence to earn on issue #102's surface,
/// and none of them silent.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum SyncGate {
    /// Sync is not configured. Nothing has been switched on and
    /// nothing can leave: the app is indistinguishable from the one
    /// that shipped before sync existed.
    Off,
    /// Configured, and no credential rests on this device.
    SignedOut,
    /// A browser ceremony is out and has not returned.
    SigningIn,
    /// A credential rested, the server refused it, and it is gone.
    Refused,
    /// A credential rests and the last attempt to use it could not
    /// reach the account server or the relay, or reached one that was
    /// unwell. The surface names no server: the state covers both, and
    /// naming the wrong one is a small lie about something the user
    /// cannot act on either way.
    Unreachable,
    /// A credential rests, nothing has refused it, and no channel is
    /// attached yet.
    Ready,
    /// The channel admitted this client.
    Attached,
}

impl SyncGate {
    /// The stable machine token that crosses the seam. Words are the
    /// shell's business; these never change spelling.
    pub(crate) fn token(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::SignedOut => "signed_out",
            Self::SigningIn => "signing_in",
            Self::Refused => "refused",
            Self::Unreachable => "unreachable",
            Self::Ready => "ready",
            Self::Attached => "attached",
        }
    }
}

/// Everything the ladder reads, gathered so the rule below is a
/// function of facts rather than of a live handle.
#[derive(Clone, Copy)]
pub(crate) struct GateInputs {
    /// The shell handed endpoints and a client id.
    pub configured: bool,
    /// A sign-in ceremony is waiting on the browser.
    pub signin_pending: bool,
    /// A credential rests on this device, in memory or in the
    /// keychain. Existence only: never a decrypting read.
    pub credential: bool,
    /// What the last attempt to use it met.
    pub fault: Option<GateFault>,
    /// The relay answered an attach and the session stands.
    pub attached: bool,
}

/// The ladder, in the order it is read.
///
/// Unconfigured wins over everything, because a client with no relay
/// cannot be anywhere with a channel it was never told about. A
/// ceremony in flight outranks the signed-out state it started from,
/// or the surface would tell a user waiting on a consent screen that
/// nothing is happening. A missing credential outranks attachment,
/// which cannot outlive it. And a network that did not answer is
/// reported as itself, never as a refusal: a server that said nothing
/// is not a server that said no, and only the second one deletes
/// anything (ADR-0027 §2).
pub(crate) fn gate(inputs: GateInputs) -> SyncGate {
    if !inputs.configured {
        return SyncGate::Off;
    }
    if inputs.signin_pending {
        return SyncGate::SigningIn;
    }
    match inputs.fault {
        Some(GateFault::Refused) => SyncGate::Refused,
        _ if !inputs.credential => SyncGate::SignedOut,
        Some(GateFault::Unreachable) => SyncGate::Unreachable,
        None if inputs.attached => SyncGate::Attached,
        None => SyncGate::Ready,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inputs() -> GateInputs {
        GateInputs {
            configured: true,
            signin_pending: false,
            credential: true,
            fault: None,
            attached: true,
        }
    }

    #[test]
    fn an_unconfigured_client_is_off_whatever_else_is_true() {
        assert_eq!(
            gate(GateInputs {
                configured: false,
                ..inputs()
            }),
            SyncGate::Off
        );
        assert_eq!(
            gate(GateInputs {
                configured: false,
                credential: false,
                attached: false,
                fault: Some(GateFault::Refused),
                signin_pending: true,
            }),
            SyncGate::Off,
            "off is silence, and silence is not qualified"
        );
    }

    #[test]
    fn a_refusal_and_a_first_run_read_differently() {
        assert_eq!(
            gate(GateInputs {
                credential: false,
                attached: false,
                ..inputs()
            }),
            SyncGate::SignedOut,
            "nothing has ever been signed in here"
        );
        assert_eq!(
            gate(GateInputs {
                credential: false,
                attached: false,
                fault: Some(GateFault::Refused),
                ..inputs()
            }),
            SyncGate::Refused,
            "the server said no and the token went with it"
        );
    }

    #[test]
    fn a_network_that_did_not_answer_is_not_a_refusal() {
        assert_eq!(
            gate(GateInputs {
                fault: Some(GateFault::Unreachable),
                ..inputs()
            }),
            SyncGate::Unreachable
        );
        // And it never reads as signed out, because the credential it
        // could not reach the server with is still resting here.
        assert_ne!(
            gate(GateInputs {
                fault: Some(GateFault::Unreachable),
                attached: false,
                ..inputs()
            }),
            SyncGate::SignedOut
        );
    }

    #[test]
    fn a_ceremony_in_flight_outranks_the_state_it_began_in() {
        assert_eq!(
            gate(GateInputs {
                signin_pending: true,
                credential: false,
                attached: false,
                ..inputs()
            }),
            SyncGate::SigningIn
        );
    }

    #[test]
    fn attachment_is_reported_only_when_nothing_is_wrong() {
        assert_eq!(gate(inputs()), SyncGate::Attached);
        assert_eq!(
            gate(GateInputs {
                attached: false,
                ..inputs()
            }),
            SyncGate::Ready
        );
        assert_eq!(
            gate(GateInputs {
                fault: Some(GateFault::Unreachable),
                ..inputs()
            }),
            SyncGate::Unreachable,
            "a standing attachment does not outrank a failed round"
        );
    }

    #[test]
    fn every_state_has_a_token_of_its_own() {
        let states = [
            SyncGate::Off,
            SyncGate::SignedOut,
            SyncGate::SigningIn,
            SyncGate::Refused,
            SyncGate::Unreachable,
            SyncGate::Ready,
            SyncGate::Attached,
        ];
        let tokens: std::collections::BTreeSet<&str> =
            states.iter().map(|state| state.token()).collect();
        assert_eq!(tokens.len(), states.len(), "no two states share a word");
    }
}
