---
name: cancel-covers-whole-ceremony
description: A cancel or abort flag must be read at every wait in a ceremony, not just the first, and a machine token with no shell sentence falls through to the worst default
metadata:
  type: feedback
---

Adversarial review of #102 found two defects of one shape: a way out
that only covered part of what it claimed to end.

**Rule: when a flag ends a multi step ceremony, read it at every step
that can wait, and once more under the lock that commits.**

**Why:** the give up flag was read only inside the loopback listener.
Once the redirect landed the ceremony still had a token exchange
ahead of it, seconds of real network, and the refresh token was then
persisted unconditionally. A user pressing Give up in that window was
told nothing was stored while a token went to the Keychain, and the
shell attached on the successful outcome, signing them in behind
their own cancel.

**How to apply:** count the waits before claiming a control ends
something. For this ceremony they are the browser trip, the token
exchange, and the commit. Write the test that opens the middle window
on purpose (a transport that raises the flag itself and then grants);
it fails against a single read.

**Rule: every machine token the core can return needs a case in the
shell's sentence function, and the default must be the most cautious
sentence, not the loudest.**

**Why:** `no_ceremony` had no case, so a cancel arriving before the
background finish call fell through to "the server refused the
sign-in". No server had been asked anything, which ADR-0027 §2
forbids. The core also had to stop spelling a user's own cancel as
`no_ceremony`.

**How to apply:** when adding a reason token in Rust, add its Swift
case in the same change, and check what the `default:` arm claims on
behalf of someone else.

Related: [[issue102-sync-surface]], [[issue98-account-gate]],
[[adversarial-review-for-agent-written-security-code]].
