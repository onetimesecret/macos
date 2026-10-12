//! Client-side sync bookkeeping: what replicates, and the gates on it
//! (ADR-0021, issues #100 and #101).
//!
//! Everything here is pure state, no IO and no crypto; the seam above
//! this crate signs and seals these values. The rules they obey are
//! ADR-0021 section 6 (in the relay decision background) for expiry,
//! hold and the terminal state; how the built client applies them, and
//! the ballot, is client protocol §6 and §7
//! (`docs/spec/feature/sync/client-protocol.md`).

use crate::sheet::ItemId;

/// What a device publishes for a page's expiry: the policy, never the
/// deadline (ADR-0021 section 6). Both halves are wall-clock values,
/// read off the live countdown, and each receiver computes its own
/// deadline from their sum, [`ExpiryPolicy::deadline_wall_ms`] (client
/// protocol §6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExpiryPolicy {
    /// Unix epoch milliseconds at the moment the countdown this policy
    /// describes was anchored.
    pub anchor_wall_ms: u64,
    /// The life the countdown had left at that moment, milliseconds.
    pub ttl_ms: u64,
}

impl ExpiryPolicy {
    /// The wall-clock instant this policy says the page dies. A
    /// receiver subtracts its own wall reading and never extends: skew
    /// that lands this in the past kills the page now, which is the
    /// minimum rule working as intended.
    #[must_use]
    pub fn deadline_wall_ms(&self) -> u64 {
        self.anchor_wall_ms.saturating_add(self.ttl_ms)
    }
}

/// The pause machine's state as it replicates, one register per page:
/// the state, never the press, applied in stream order, and a live hold
/// suspends the countdown everywhere (ADR-0021 section 6; client
/// protocol §6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HoldRegister {
    /// No hold stands; the countdown runs.
    Released,
    /// The countdown is frozen with `frozen_ms` of life remaining, and
    /// the hold lapses at `until_wall_ms`, computed by the holding
    /// device on its own clock, skew accepted.
    Held {
        /// Unix epoch milliseconds when the hold lapses on its own.
        until_wall_ms: u64,
        /// The remaining life frozen by the hold, milliseconds.
        frozen_ms: u64,
        /// Whether the hold has been topped up to its 24 hour ceiling.
        topped_up: bool,
    },
}

/// The signed fact of a page's death: published once, by a device the
/// gate below admits, and absorbing — after it, every delta for the
/// page is refused and the page's key is destroyed, which kills the
/// relay's buffered ciphertext for everyone at once (ADR-0021 section
/// 6). The signature is the seam's business, not this crate's; what
/// travels through here is the claim.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalMarker {
    /// The dead page.
    pub page: ItemId,
    /// Unix epoch milliseconds at the publishing device when it
    /// entombed its copy. A stamp a human reads in a ledger, never an
    /// input to another device's expiry math.
    pub at_wall_ms: u64,
}

/// How a channel answers a delta offered for a page, given the epoch
/// the delta claims.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeltaAdmission {
    /// The delta belongs to the current GOP: apply it through
    /// [`SheetStore::apply_remote_update`], whose own checks still
    /// stand.
    ///
    /// [`SheetStore::apply_remote_update`]: crate::store::SheetStore::apply_remote_update
    Apply,
    /// The delta is from another epoch — this device slept through a
    /// ceremony, or the sender did. Either way the recovery is the
    /// same: drop the pre-ceremony history and rejoin at the current
    /// key frame, never ask for the ops behind it (ADR-0021 sections 1
    /// and 5).
    RejoinRequired,
    /// The page is terminal. Nothing lands on it again.
    Refused,
}

/// One proposed compaction ceremony: who must confirm, and who has.
/// A ballot that does not fill leaves this device on the old GOP;
/// whom it names is the caller's choice (client protocol §7.3, §7.7).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CeremonyBallot {
    /// The devices the proposal names, the proposer included (client
    /// protocol §7.3). Every one of them must accept.
    attached: Vec<ItemId>,
    /// The devices that have accepted so far.
    accepted: Vec<ItemId>,
}

impl CeremonyBallot {
    /// Whether every attached device has accepted. Only a confirmed
    /// ballot may perform the ceremony — the key rotation and the
    /// document rebuild, two halves of one event.
    #[must_use]
    pub fn confirmed(&self) -> bool {
        self.attached
            .iter()
            .all(|device| self.accepted.contains(device))
    }

    /// Record `device`'s acceptance. A device the proposal did not
    /// name cannot vote: it attached after the proposal, and it joins
    /// the *next* GOP by rejoining at the key frame the ceremony
    /// writes, not by wedging this one open.
    pub fn accept(&mut self, device: ItemId) -> bool {
        if !self.attached.contains(&device) {
            return false;
        }
        if !self.accepted.contains(&device) {
            self.accepted.push(device);
        }
        true
    }
}

/// One page's standing on its sync channel, as this device sees it:
/// the GOP epoch, whether this device's view is current, the hold
/// register as last synced, the terminal flag, and the ceremony in
/// flight if there is one. The session layer feeds it from the wire;
/// the store never sees it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PageChannel {
    /// How many ceremonies this channel has completed. A delta carries
    /// the epoch it was published under; only the current epoch's
    /// deltas apply.
    epoch: u64,
    /// Whether this device has drained the channel since it last
    /// attached: true after a fetch reaches the channel's frontier,
    /// false the moment the connection drops. This is the register
    /// currency the terminal gate reads.
    current: bool,
    /// Whether the hold register, as last synced, holds the page.
    hold_live: bool,
    /// Whether a terminal marker has been observed or published for
    /// this page. Absorbing: nothing clears it.
    terminal: bool,
    /// The ceremony in flight, if one was proposed and has neither
    /// confirmed nor been abandoned.
    ballot: Option<CeremonyBallot>,
}

impl PageChannel {
    /// A fresh channel view: epoch zero, not current, no hold, no
    /// ceremony.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The channel's GOP epoch as this device knows it.
    #[must_use]
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// Record whether this device's view of the channel is current:
    /// the session layer sets it true when a fetch drains the channel
    /// to its frontier and false the moment the connection drops or a
    /// fetch fails.
    pub fn set_current(&mut self, current: bool) {
        self.current = current;
    }

    /// Record the hold register as last synced, so the terminal gate
    /// knows whether a hold stands.
    pub fn note_hold(&mut self, register: HoldRegister) {
        self.hold_live = matches!(register, HoldRegister::Held { .. });
    }

    /// How to treat a delta published under `epoch`.
    #[must_use]
    pub fn admit_delta(&self, epoch: u64) -> DeltaAdmission {
        if self.terminal {
            DeltaAdmission::Refused
        } else if epoch == self.epoch {
            DeltaAdmission::Apply
        } else {
            DeltaAdmission::RejoinRequired
        }
    }

    /// The one gate on who may declare a synced page dead (ADR-0021
    /// section 6): only a device whose view of the hold register is
    /// current with the channel, and only while no hold stands. A
    /// device that expired the page while offline entombs its own copy
    /// on its own clock — that stays its right — but it may not
    /// publish the marker, because it cannot know whether a hold it
    /// never saw is keeping the page alive everywhere else. On
    /// reconnecting it either learns the page died (and its silence
    /// cost nothing) or finds it alive under a hold and rejoins at the
    /// current key frame.
    #[must_use]
    pub fn may_publish_terminal(&self) -> bool {
        self.current && !self.hold_live && !self.terminal
    }

    /// Record a page's death, observed or published. Absorbing: every
    /// later delta refuses, and no ceremony will run again.
    pub fn note_terminal(&mut self) {
        self.terminal = true;
        self.ballot = None;
    }

    /// Whether the page is terminal.
    #[must_use]
    pub fn is_terminal(&self) -> bool {
        self.terminal
    }

    /// Open a ballot naming `attached`, the proposer included. Returns
    /// whether a ballot opened: a second proposal while one is in
    /// flight is refused rather than stacked, and a terminal page holds
    /// no ceremonies at all.
    pub fn propose_ceremony(&mut self, attached: &[ItemId]) -> bool {
        if self.terminal || self.ballot.is_some() || attached.is_empty() {
            return false;
        }
        self.ballot = Some(CeremonyBallot {
            attached: attached.to_vec(),
            accepted: Vec::new(),
        });
        true
    }

    /// Record `device`'s acceptance of the ceremony in flight. False
    /// when no ballot stands or the device was not named by the
    /// proposal.
    pub fn accept_ceremony(&mut self, device: ItemId) -> bool {
        self.ballot
            .as_mut()
            .is_some_and(|ballot| ballot.accept(device))
    }

    /// Whether every device the ballot names has accepted: the moment,
    /// and the only moment, the two halves of the event may run:
    /// rotate the GOP key and rebuild the document
    /// ([`SheetStore::perform_ceremony`]), then call
    /// [`PageChannel::complete_ceremony`].
    ///
    /// [`SheetStore::perform_ceremony`]: crate::store::SheetStore::perform_ceremony
    #[must_use]
    pub fn ceremony_confirmed(&self) -> bool {
        self.ballot.as_ref().is_some_and(CeremonyBallot::confirmed)
    }

    /// Close a confirmed ceremony: the epoch advances and the ballot
    /// clears. Refuses (false) unless the ballot is confirmed, so an
    /// epoch can never advance on a partial vote.
    pub fn complete_ceremony(&mut self) -> bool {
        if !self.ceremony_confirmed() {
            return false;
        }
        self.ballot = None;
        self.epoch += 1;
        true
    }

    /// Abandon the ceremony in flight — the proposer died, a device
    /// refused, or the proposal timed out. Every device stays on the
    /// old GOP: the epoch does not move, and the next transition may
    /// propose again.
    pub fn abandon_ceremony(&mut self) {
        self.ballot = None;
    }

    /// Adopt the channel's epoch after rejoining at the current key
    /// frame: the one legal way to cross a ceremony boundary this
    /// device slept through (ADR-0021 section 5). The pre-ceremony
    /// history was dropped by the rejoin
    /// ([`SheetStore::adopt_key_frame`] only lands on a fresh page),
    /// so adopting the number is honest by the time it happens.
    ///
    /// [`SheetStore::adopt_key_frame`]: crate::store::SheetStore::adopt_key_frame
    pub fn rejoin_at_epoch(&mut self, epoch: u64) {
        self.epoch = epoch;
        self.ballot = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device() -> ItemId {
        ItemId::random()
    }

    #[test]
    fn a_ballot_confirms_only_when_every_attached_device_accepts() {
        let (a, b, c) = (device(), device(), device());
        let mut channel = PageChannel::new();
        assert!(channel.propose_ceremony(&[a, b, c]));
        assert!(!channel.ceremony_confirmed());
        assert!(channel.accept_ceremony(a));
        assert!(channel.accept_ceremony(b));
        assert!(!channel.ceremony_confirmed(), "one vote is still out");
        assert!(channel.accept_ceremony(c));
        assert!(channel.ceremony_confirmed());
        assert!(channel.complete_ceremony());
        assert_eq!(channel.epoch(), 1);
    }

    #[test]
    fn an_unconfirmed_ceremony_leaves_every_device_on_the_old_gop() {
        let (a, b) = (device(), device());
        let mut channel = PageChannel::new();
        assert!(channel.propose_ceremony(&[a, b]));
        assert!(channel.accept_ceremony(a));
        // The epoch must not move on a partial vote…
        assert!(!channel.complete_ceremony());
        assert_eq!(channel.epoch(), 0);
        // …and abandoning keeps everyone where they were, free to
        // propose again at the next transition.
        channel.abandon_ceremony();
        assert_eq!(channel.epoch(), 0);
        assert!(channel.propose_ceremony(&[a, b]));
    }

    #[test]
    fn a_late_attacher_cannot_vote_and_a_second_proposal_cannot_stack() {
        let (a, b, late) = (device(), device(), device());
        let mut channel = PageChannel::new();
        assert!(channel.propose_ceremony(&[a, b]));
        assert!(!channel.accept_ceremony(late), "not named by the proposal");
        assert!(!channel.propose_ceremony(&[a, b, late]));
    }

    #[test]
    fn deltas_admit_by_epoch_and_a_stale_device_rejoins() {
        let (a, b) = (device(), device());
        let mut channel = PageChannel::new();
        assert_eq!(channel.admit_delta(0), DeltaAdmission::Apply);
        assert!(channel.propose_ceremony(&[a, b]));
        assert!(channel.accept_ceremony(a));
        assert!(channel.accept_ceremony(b));
        assert!(channel.complete_ceremony());
        // A delta from behind the boundary, or a device behind it
        // offering anything at all: rejoin, never backfill.
        assert_eq!(channel.admit_delta(0), DeltaAdmission::RejoinRequired);
        assert_eq!(channel.admit_delta(1), DeltaAdmission::Apply);

        let mut stale = PageChannel::new();
        assert_eq!(stale.admit_delta(1), DeltaAdmission::RejoinRequired);
        stale.rejoin_at_epoch(1);
        assert_eq!(stale.admit_delta(1), DeltaAdmission::Apply);
    }

    #[test]
    fn the_terminal_gate_needs_a_current_view_and_no_live_hold() {
        let mut channel = PageChannel::new();
        assert!(
            !channel.may_publish_terminal(),
            "a device that never drained the channel may not declare a death"
        );
        channel.set_current(true);
        assert!(channel.may_publish_terminal());
        channel.note_hold(HoldRegister::Held {
            until_wall_ms: 1,
            frozen_ms: 1,
            topped_up: false,
        });
        assert!(!channel.may_publish_terminal(), "the hold wins");
        channel.note_hold(HoldRegister::Released);
        assert!(channel.may_publish_terminal());
        channel.set_current(false);
        assert!(!channel.may_publish_terminal(), "offline again");
    }

    #[test]
    fn terminal_is_absorbing() {
        let (a, b) = (device(), device());
        let mut channel = PageChannel::new();
        channel.set_current(true);
        channel.note_terminal();
        assert_eq!(channel.admit_delta(0), DeltaAdmission::Refused);
        assert!(!channel.may_publish_terminal(), "the death is already told");
        assert!(!channel.propose_ceremony(&[a, b]));
        assert!(channel.is_terminal());
    }
}
