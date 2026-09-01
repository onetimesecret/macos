# Sync enrolment on two machines: the browser trip, the six digits, and the revoke

**Applies to:** OnetimePad, installed release bundle, on two Macs
signed in to the same Onetime Secret account, against a running relay.
**Required by:** issue
[#102](https://github.com/onetimesecret/macos/issues/102) and
[ADR-0027](../../adr/0027-account-auth-gates-the-sync-channel.md)
section 5, whose seven gate states each owe the surface a word, and
[ADR-0021](../../adr/0021-multi-device-sync-over-a-blind-relay.md)
section 3, whose pairing must be failable by a human.
**Owner:** delano.
**Status:** blocked on the relay. Not yet run on hardware.

## Why this is not in CI

Three things here cannot be reached by a test on one machine.

1. **The browser trip is a real browser.** The suite drives the
   loopback listener directly and never opens a consent screen, so
   nothing automated has ever seen a redirect arrive from Safari, a
   closed tab, or a second app claiming the port.
2. **Pairing needs two devices with two screens.** The six digits are
   compared by a person looking at both, which is the whole point of a
   short authentication string, and a test that compares them for
   itself verifies nothing.
3. **Revocation is a claim about the future.** What it promises is
   that key rotations this Mac starts seal nothing new to the revoked
   device, which takes a second device that keeps running and a later
   ceremony to observe.

Every automated test in this area runs against
`InMemoryCredentialStore` and the transport doubles, so a real
Keychain, a real account server and a real relay are all first seen
here.

## Setting up

On each Mac, quit any running copy first (`scripts/quit-app.sh`, since
only the graceful path saves state), then install and launch:

```sh
pgrep -fl "OnetimePad"
scripts/install.sh
```

Both Macs need the same account, a reachable relay, and the relay URL
in the settings defaults. The relay has no default and the app will
not invent one:

```sh
defaults write com.onetimesecret.companion.backdrop sync.relayURL "https://<relay host>"
defaults read  com.onetimesecret.companion.backdrop sync.enabled     # expect absent, or 0
```

A log stream on each machine is worth a second terminal:

```sh
log stream --style compact --predicate \
  'subsystem == "com.onetimesecret.companion.backdrop"'
```

Name the machines A and B for the rows below. A signs in first and
founds the channel; B joins it.

## Check 1: off is off

Before anything is enabled, on machine A.

- [ ] **Look at the header.** Expected: the persistence word and
      nothing beside it. No sync word of any kind.
- [ ] **Open Settings.** Expected: one sync control, the switch,
      turned off. No device list, no sign in, no pairing.
- [ ] **Watch the network while typing a page and sealing a chip.**
      Expected: nothing. A `nettop -p` filtered on the app, or Little
      Snitch, shows no connection to the relay host or the account
      host. The core loop is untouched.

**Fail:** any sync word in the header, any control beyond the switch,
or a single packet to either host.

## Check 2: the browser trip and the way out

On machine A, turn the switch on. The page should say sync is signed
out; the header should say `sync signed out`.

- [ ] **Press Sign in.** Expected: the default browser opens on the
      account server's consent screen. The header changes to
      `signing in`, the page says it is waiting on the browser, and
      Settings shows a spinner with a Give up beside it.
- [ ] **Close the browser tab without consenting, then press Give
      up.** Expected: within a second or two, the header returns to
      `sync signed out`, Settings says the sign in was given up and
      nothing was stored, and the Give up disappears. Time it: a wait
      that runs on for minutes is the defect this check exists for.

  ```sh
  security find-generic-password -s com.onetimesecret.companion.backdrop \
    -a sync-oauth-refresh   # expect: not found
  ```

- [ ] **Press Sign in and then Give up immediately**, before the
      consent screen has finished loading. Expected: the same given up
      sentence. It must never read as the server refusing the sign in:
      no server was asked anything, and the cancel racing the app's
      own background call is the ordinary case rather than a rare one.
- [ ] **Press Sign in, complete the consent, and press Give up as the
      browser hands back.** This one is a race and may take several
      attempts to land inside; the window is the token exchange, which
      is one network round trip wide. Expected: one of two outcomes
      and never a mixture. Either the sign in completed, Settings says
      so and the item below exists, or Settings says the sign in was
      given up and the item below does not exist. A Settings that says
      given up over a Keychain that holds a token, or an app that
      attaches after saying it, is the defect.

  ```sh
  security find-generic-password -s com.onetimesecret.companion.backdrop \
    -a sync-oauth-refresh
  ```

- [ ] **Press Sign in, and with the consent screen still open turn the
      sync switch off.** Expected: the header says nothing at all, and
      the item below does not exist however long you leave the browser
      tab open afterwards. Consenting after the switch went off must
      store nothing: the switch ends the trip, and a token that
      arrives for a session nobody is in is not a sign in.

  ```sh
  security find-generic-password -s com.onetimesecret.companion.backdrop \
    -a sync-oauth-refresh   # expect: not found
  ```

- [ ] **Turn the switch off and straight back on while sync is
      attached.** Expected: the surface settles on the new session
      within a poll and never shows a page marked as being written
      elsewhere by the session that ended, nor a `sync behind` it
      reported.

- [ ] **Press Sign in again and complete the consent.** Expected: the
      browser says the tab can be closed, the header goes to
      `reaching` and then `synced`, and Settings lists this Mac.
- [ ] **Answer any Keychain prompt that appears.** Note which item it
      names and at what moment: key access happens on use (ADR-0004),
      and a prompt at launch would be a regression.
- [ ] **Quit and relaunch.** Expected: signed in with no browser, one
      refresh round trip. The header reaches `synced` without a
      consent screen.

**Fail:** a Give up that does not end the wait, a refresh token
present after an abandoned or given up ceremony or after the switch
went off mid trip, a cancel described as a server refusal, a prompt at
launch, or a relaunch that asks for the browser again.

## Check 3: pairing, and failing it on purpose

Machine B: turn the switch on and sign in the same way. Both machines
now pass the account gate and neither can read the other's pages.

- [ ] **Look at each device list.** Expected: each shows itself, and
      may show the other as **attached, never paired** in ember. That
      is correct and is the state ADR-0021 section 5 describes: past
      the account gate, past no pairing, holding ciphertext it cannot
      open.
- [ ] **On A press Invite a device, on B press Join from here.**
      Expected: both show a spinner, then the same six digits.
- [ ] **Compare them, then press "They don't match" on B.** Expected:
      both ceremonies end, both say the strings did not match and
      nothing was stored, and neither device list gains a paired row.
      This is the check that the comparison can fail.
- [ ] **Run it again and press "They match" on both.** Expected: both
      say paired, and each device list gains the other with a
      fingerprint head and a seen time.

**Fail:** digits that differ between the screens, a mismatch that
pairs anyway, or a pairing that leaves a row on only one machine.

## Check 4: pages travelling, and the mark

- [ ] **On A, choose "Sync this page to your devices" from a page's
      tab menu, and type.** Expected: within a few seconds the same
      text appears on B, in a page of its own.
- [ ] **While A is typing, watch B's page.** Expected: B shows
      **another device is editing this page** under the page, in
      quiet text, and never a dialog. It goes away roughly a minute
      and a half after A stops.
- [ ] **Put B to sleep, then type on A.** Expected: A's header reads
      `sync waiting` rather than `synced`, and the page says no other
      device is awake.
- [ ] **Wake B.** Expected: B catches up, and A returns to `synced`.
- [ ] **Pull the network on A.** Expected: A's header reads
      `sync offline` in ember, the page says the relay cannot be
      reached and edits stay local, and typing continues to work and
      to save. Restore the network: A returns to `synced` on its own
      without a relaunch.

**Fail:** a page that does not travel, an edit lost in either
direction, a mark that never appears or never leaves, or a network
failure that stops the pad from working or saving.

## Check 5: revocation

- [ ] **On A, revoke B.** Expected: the confirmation says this Mac
      stops sealing anything new to it at the next key rotation this
      Mac starts, that a device paired from another Mac must be
      revoked there too, and that what it already holds, it holds.
      Confirm.
- [ ] **Look at A's device list.** Expected: B is gone, or shown as an
      attached stranger if it is still on the channel.
- [ ] **Type on A's shared page.** Expected: B stops receiving it once
      the next ceremony runs. What B already had, B keeps.
- [ ] **On B, look at its own list.** Expected: A is still listed
      there, because revocation is this Mac's own trust and not a
      claim over the other machine's. Revoke A on B as well and
      confirm both lists agree.

**Fail:** B still receiving new edits after the next ceremony, B's
existing content disappearing, or a revoke that silently reaches
across to the other machine's records.

## Check 6: signing out, and what it must not take with it

- [ ] **On A, press Sign out of sync and confirm.** Expected: the
      header reads `sync signed out`, the page says the pad is
      unaffected, and every page, sealed chip and tab name is exactly
      as it was.

  ```sh
  security find-generic-password -s com.onetimesecret.companion.backdrop \
    -a sync-oauth-refresh   # expect: not found
  security find-generic-password -s com.onetimesecret.companion.backdrop \
    -a api-token            # expect: still there
  ```

- [ ] **Conceal a page.** Expected: the conceal still works, which is
      the credential separation of ADR-0027 section 3 seen from the
      user's side.
- [ ] **Turn the switch off.** Expected: the header word goes, the
      page's sync line goes, the device list goes, and check 1's
      conditions hold again.

**Fail:** a sign out that takes the conceal token, a page, a chip or a
pairing record with it.

## Results

Not yet run. One row per check when a session runs it, and the rows
stay: a re-run adds a row rather than replacing one.

| Date | Machines and macOS | Check | Pass or fail | Notes |
|---|---|---|---|---|
| | | 1 off is off | | Record whether any packet left. |
| | | 2 browser trip and give up | | Record how long the give up took. |
| | | 2 give up before the consent loads | | Never the server refusal sentence. |
| | | 2 give up during the token exchange | | Record how many attempts to land in the window. |
| | | 2 relaunch resumes without a browser | | Record any Keychain prompt and when. |
| | | 3 pairing fails on a mismatch | | |
| | | 3 pairing succeeds on a match | | |
| | | 4 a page travels both ways | | |
| | | 4 the editing mark appears and lapses | | |
| | | 4 nobody awake reads as waiting | | |
| | | 4 no network reads as offline and recovers | | |
| | | 5 revoke stops new edits at the next ceremony | | Note which ceremony and when. |
| | | 5 revoke does not reach the other machine | | |
| | | 6 sign out leaves the pad and the conceal token | | |
