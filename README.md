# OTS Cache — macOS companion for Onetime Secret

> **Working title.** The product name is unsettled; `OTS Cache` is a placeholder
> that captures the intent. See the naming note in the spec.

A small, native macOS app that gives sensitive content a safe, self-clearing
place to rest **while it is in transit** — the moment between copying something
out of one place and pasting it into another. It lives in the menu bar and, when
you want it, as a quiet panel docked to the edge of the screen.

It is the **open-source desktop companion** to
[Onetime Secret](https://onetimesecret.com). Its primary job is local and needs
no account: park clipboard text or an image in a **SleeperCell** that expires on
its own. Its secondary job is one gesture away: promote any cell into a secure,
one-time [Onetime Secret](https://onetimesecret.com) link.

## Status

**Skeleton prototype landing — the Rust trust core is real and green.**

The design docs came first; now the skeleton from
[docs/01](docs/01-repo-skeleton.md) is stood up. The portable Rust core
(`ots-core`) — `SecretBuffer`, the `SleeperCell` + bounded store, the TTL
ladder, redacted previews, credential storage, and the v3 `conceal` client — is
implemented and fully unit-tested. The C-ABI seam (`ots-ffi`) hands the UI only
handles, non-secret summaries, and share links; a test asserts no plaintext ever
crosses it. The Swift/SwiftUI shell (`apps/OTSCache`) is scaffolded as the
vertical-slice, ready to build against the generated `.xcframework` on macOS.

- 📄 **[docs/00-problem-space.md](docs/00-problem-space.md)** — the Milestone 1
  document: what problem this solves, what everyone else overlooks, the design
  ethos, and the questions deferred to later milestones.
- 🧱 **[docs/01-repo-skeleton.md](docs/01-repo-skeleton.md)** — the prescription
  for standing up the repo and app skeleton: the Rust-core + Swift-UI split, the
  "secret bytes never enter Swift" boundary, the toolchain, and the ordered
  bootstrap sequence.

### What runs today

```sh
scripts/bootstrap.sh        # one-command dev setup
scripts/check.sh            # fmt + clippy + tests (+ deny/swift where available)
cargo test -p ots-core      # the portable trust core — fully testable on any Unix host
scripts/build-core.sh       # (macOS) build bindings/OtsCore.xcframework for the Swift app
```

The core builds and tests on Linux and macOS; the Swift shell and the real
Keychain path build on macOS. The `NSPasteboard` reader and a live-credential
`conceal` are the next spike (docs/01 §10 step 7).

### Layout

| Path | What |
|------|------|
| `crates/ots-core` | The trust core — secrets, cells, TTL, keychain, API. Portable Rust, no Apple assumptions. |
| `crates/ots-ffi` | The only crate exposed to Swift. A thin C ABI; handles and outputs only, never plaintext. |
| `apps/OTSCache` | The Swift/SwiftUI shell (menu bar + edge-docked panel). macOS only. |
| `bindings/` | Generated seam (`.xcframework`), git-ignored. The boundary made visible in the tree. |
| `scripts/` | `bootstrap.sh`, `build-core.sh`, `check.sh`. |

## The one-paragraph version

The system clipboard is a single volatile register: copy something new and the
last thing is gone. The market's answer is the clipboard-history app — a
searchable archive that keeps *everything forever*, quietly accumulating every
password and 2FA code you have ever copied. We want the opposite. Think of it as
an **L1/L2 cache for content in transit**: a small, bounded set of slots that
hold your working set *right now* and then evict themselves. Forgetting is the
default. Keeping costs a deliberate click.

## Principles (short form)

- **Ephemeral by default.** Expiry is the resting state; permanence is the
  exception. Forgetting is free; keeping costs a click.
- **Content plays second fiddle.** The *state* — time remaining, security,
  transit — is the star. Cells preview content; they don't edit it.
- **Present, not central.** An ambient edge-docked panel that is there when you
  glance and gone when you don't. It never steals focus.
- **Frugal.** Small in memory, disk, CPU, battery, pixels, and cognition. Native
  Rust, not a browser in a trench coat.
- **Accessible first.** Full keyboard control; the countdown never relies on
  colour or motion alone; Reduce Motion / Increase Contrast / Dynamic Type are
  first-class.
- **Local-first and private.** Sensitive transit content does not silently
  persist or sync. The network is opt-in and only for sharing.

## License

MIT — see [LICENSE](LICENSE).
