import SwiftUI

/// The sync controls, inside the one Settings surface (issue #102):
/// the off switch first, then — only while sync is on — the sign-in,
/// the device list with its revocations, and the pairing flow with
/// the six digits a human compares. No second settings surface, and
/// nothing here while the switch is off beyond the switch itself.
struct SyncSettingsSection: View {
    @ObservedObject var sync: SyncController

    @State private var confirmingSignout = false

    var body: some View {
        Section {
            Toggle("Sync between your devices", isOn: $sync.enabled)
            if sync.enabled {
                if let line = sync.settingsLine {
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(
                            sync.settingsLineIsTrouble ? Color.ember : Color.secondary)
                }
                if sync.status?.signedIn == true {
                    Button("Sign out of sync") { confirmingSignout = true }
                        .confirmationDialog(
                            "Sign out of sync?",
                            isPresented: $confirmingSignout,
                            titleVisibility: .visible
                        ) {
                            Button("Sign out", role: .destructive) { sync.signOut() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(
                                "Sync stops until you sign in again. Pages, sealed chips and the conceal token are untouched."
                            )
                        }
                } else {
                    Button("Sign in…") { sync.signIn() }
                        .disabled(sync.status?.signinPending == true)
                }
            }
        } header: {
            Text(syncCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if sync.enabled, sync.status?.signedIn == true {
            Section {
                if sync.devices.isEmpty {
                    Text("no devices yet")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ForEach(sync.devices) { device in
                    SyncDeviceRow(device: device, sync: sync)
                }
                if let stage = sync.pairingStage {
                    SyncPairingStatus(stage: stage, sync: sync)
                } else {
                    HStack {
                        Button("Invite a device…") { sync.beginInvite() }
                        Button("Join from here…") { sync.beginJoin() }
                    }
                }
            } header: {
                Text(devicesCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The switch's caption carries the promise the switch guards: off
    /// is the default and off is silence, and even on, a page travels
    /// only to devices a human paired, only sealed.
    private var syncCaption: String {
        "Off by default, and off means nothing: no account, no network, no change. "
            + "On, pages you choose travel sealed between devices you pair yourself by "
            + "comparing six digits on both screens — the relay between them carries "
            + "ciphertext it cannot read, and a page's expiry travels with it."
    }

    private var devicesCaption: String {
        "Devices on this channel. Revoking one removes this Mac's trust in it: key "
            + "rotations this Mac starts seal nothing new to it. A device paired from "
            + "more than one Mac must be revoked on each; each page's context menu "
            + "chooses which pages travel at all."
    }
}

/// One device row: the fingerprint's head, a name, and what the row
/// is — this Mac, a paired device, or an attached stranger no pairing
/// vouches for, which is a fact worth showing exactly as loudly as
/// this.
private struct SyncDeviceRow: View {
    let device: SyncDevice
    @ObservedObject var sync: SyncController

    @State private var confirmingRevoke = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(device.fingerprint.prefix(8)))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
            Spacer()
            Text(badge)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(device.verified ? Color.secondary : Color.ember)
            if !device.thisDevice, device.verified {
                Button("Revoke", role: .destructive) { confirmingRevoke = true }
                    .controlSize(.small)
                    .confirmationDialog(
                        "Revoke this device?",
                        isPresented: $confirmingRevoke,
                        titleVisibility: .visible
                    ) {
                        Button("Revoke", role: .destructive) {
                            sync.revoke(fingerprint: device.fingerprint)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "This Mac stops sealing anything new to it at the next key rotation this Mac starts. If it was also paired from another Mac, revoke it there too. What it already holds, it holds."
                        )
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(badge)"))
    }

    private var title: String {
        if device.thisDevice { return "this Mac" }
        return device.label.isEmpty ? "paired device" : device.label
    }

    private var badge: String {
        if device.thisDevice { return "attached" }
        if !device.verified { return "attached, never paired" }
        return device.attachedMs == nil ? "away" : "attached"
    }
}

/// The pairing flow inline: a spinner while messages cross, the six
/// digits large when both sides settle, and the two verdicts — with
/// the failing one always offered, because a comparison that cannot
/// fail verifies nothing (ADR-0021 §3).
private struct SyncPairingStatus: View {
    let stage: SyncPairingStage
    @ObservedObject var sync: SyncController

    var body: some View {
        switch stage.stage {
        case "sas":
            VStack(alignment: .leading, spacing: 6) {
                Text("Compare with the other device's screen. Continue only on a match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(stage.sas ?? "")
                    .font(.system(.title2, design: .monospaced))
                    .accessibilityLabel(Text("Verification digits \(stage.sas ?? "")"))
                HStack {
                    Button("They match") { sync.confirmPairing(matched: true) }
                    Button("They don't match", role: .destructive) {
                        sync.confirmPairing(matched: false)
                    }
                }
            }
        case "failed":
            HStack {
                Text(SyncController.pairingSentence(stage: stage.stage, reason: stage.reason))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.ember)
                Spacer()
                Button("Dismiss") { sync.cancelPairing() }
                    .controlSize(.small)
            }
        case "done":
            HStack {
                Text(SyncController.pairingSentence(stage: stage.stage, reason: nil))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { sync.cancelPairing() }
                    .controlSize(.small)
            }
        default:
            HStack {
                ProgressView().controlSize(.small)
                Text(SyncController.pairingSentence(stage: stage.stage, reason: nil))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { sync.cancelPairing() }
                    .controlSize(.small)
            }
        }
    }
}
