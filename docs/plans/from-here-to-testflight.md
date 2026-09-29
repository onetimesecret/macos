# From Here to TestFlight

> Historical implementation plan, not the current submission procedure.
> For the implemented packaging command and account-to-tester workflow, use
> [Distributing OnetimePad through TestFlight](../development/testflight-distribution.md).
> The steps below predate the App Store packaging lane; their signing examples,
> version-stamping instructions, and runtime assumptions are not current guidance.

Two current Apple requirements shape everything below: Mac TestFlight requires a provisioning profile, which macOS only issues when a restricted entitlement demands one, and without an Xcode project the upload path is a signed `.pkg` delivered via Transporter.

The starting point is further along than it might appear: `package-app.sh` already produces `dist/OnetimePad.app` with the bundle id `com.onetimesecret.pad` and version stamping, and the Rust core is a static `.a` linked into one Mach-O (no embedded dylib to sign separately, which simplifies everything). What's missing for TestFlight is the App Store distribution chain: sandbox, entitlements, a real Distribution identity, a provisioning profile, a signed `.pkg`, and an App Store Connect record.

One decision up front, since it's the only real fork: keep the SwiftPM + scripts pipeline and manage the cert/profile/`.pkg` by hand, or add a thin Xcode target (or `xcodebuild -exportArchive`) and let automatic signing do it. I'd keep your scripts for the build and add the distribution signing to them, because the boundary-clean SwiftPM build is worth preserving. But be honest with yourself: cert creation, profile management, and the App-Store re-sign are exactly what Xcode automates, so if step 5 below starts eating your evening, wrapping it in Xcode is the escape hatch, not a failure.

The steps, in order:

1. **Apple Developer Program.** Paid membership if you don't have one. Note your Team ID.

2. **Register the App ID.** In Certificates, Identifiers & Profiles, create an explicit identifier matching `com.onetimesecret.pad`, and enable Keychain Sharing on it. (The dev lane is `dev.onetimesecret.pad`, a separate prefix; it never ships through this chain.)

3. **Create the App Store Connect record.** New macOS app, select that bundle id, set name, SKU, primary language. Decide the real product name here (see the naming note below).

4. **Add App Sandbox and entitlements.** This is the actual work. `scripts/Companion.entitlements` already exists and already carries the keychain group; extend that file rather than creating a second one:
   - `com.apple.security.app-sandbox` = true (mandatory for anything shipped through App Store Connect)
   - `com.apple.security.network.client` = true (the conceal POST and the connection test)
   - `keychain-access-groups`, already present as `$(AppIdentifierPrefix)@BUNDLE_IDENTIFIER@`. Do not hardcode a bundle id here: the build scripts substitute the signing certificate's Team ID and the id of the bundle being assembled, so the release bundle and the `dev.onetimesecret.pad` dev bundle each land in their own group. A single shared group would be a single shared keychain, which ADR-0012 forbids across the dev and release lanes. This entitlement also does double duty: it is the restricted one that forces macOS to issue a genuine provisioning profile, which is what makes Mac TestFlight work at all. Restricted cuts both ways, though, so see step 5: claim it without embedding a profile and the app will not launch (amfid -413).

5. **Certificates and profile.** An "Apple Distribution" certificate signs the `.app`; a "Mac Installer Distribution" (a.k.a. "3rd Party Mac Developer Installer") certificate signs the `.pkg`. Create a Mac App Store distribution provisioning profile for the App ID and copy it to `Contents/embedded.provisionprofile` before signing. App Store re-signs your build on ingest, so the embedded profile is for upload validation, not the final identity.

6. **Extend `package-app.sh` for distribution.** Replace the ad-hoc sign with a real one, adding hardened runtime and the entitlements:

   ```
   codesign --force --options runtime \
     --entitlements scripts/Companion.entitlements \
     --sign "Apple Distribution: Onetime Secret (TEAMID)" \
     dist/OnetimePad.app
   ```

   You already parameterized `CODESIGN_IDENTITY`, so this is a small change plus the two new flags.

7. **Add the App Store Info.plist keys.** The earlier instruction to set `ITSAppUsesNonExemptEncryption` to `true` solely because the app uses `ring` and `rustls` was incorrect. Follow [App encryption and export compliance](../development/encryption-export-compliance.md) for the current questionnaire-based declaration and the separate documentation process for adding France. Do not invent or prefill a compliance code.

   Ensure `CFBundleVersion` increments on every upload; it's stamped from `CFBundleShortVersionString` plus the short commit, so a resubmit from the same commit without a version bump will be rejected as a duplicate build number.

   **Where the version lives.** `CFBundleShortVersionString` in `shell/OnetimePad-Info.plist` is the app's marketing version and its own source of truth (issue #89). Bump it there, by hand, when work a user can touch lands, the same way `crates/ffi/Cargo.toml` gets bumped when the seam changes. The two numbers are separate facts about separate artifacts: the app's says what the product does now, the core's says what the FFI seam offers, and `package-app.sh` prints both when it assembles the bundle. The packaging script refuses the `0.0.0` placeholder, so a bundle that ships has a real number in it.

8. **Build the installer package:**

   ```
   productbuild --component dist/OnetimePad.app /Applications \
     --sign "3rd Party Mac Developer Installer: Onetime Secret (TEAMID)" \
     OnetimePad.pkg
   ```

9. **Upload.** Since there's no Xcode archive, use the Transporter app (drag the `.pkg`, Verify, Deliver) or `xcrun altool` / iTMSTransporter with an App Store Connect API key. Apple notarizes the App Store build during processing, so you do not run `notarytool` yourself on this lane.

10. **Turn on TestFlight.** Once the build finishes processing in App Store Connect, add internal testers (up to 100, no review). External testers require a brief Beta App Review first.

Where sandboxing will actually bite this app, in priority order:

**Keychain is the one to verify on device.** The core uses `security-framework` generic-password items scoped by service name with no explicit `kSecAttrAccessGroup` (`crates/credentials/src/lib.rs`). Under sandbox those land in the app's own keychain automatically, and with the `keychain-access-groups` entitlement whose first group is the app id, store/load/exists/delete stay consistent across TestFlight builds (Apple signs them all with the same App Store identity, so the ACL doesn't re-prompt the way your ad-hoc rebuilds do). But this is the single highest-risk integration point; test the full save-token, relaunch, conceal round trip in the sandboxed build before trusting it.

**The ⌃⌥Space hotkey survives.** Carbon `RegisterEventHotKey` (`BackdropHotKey.swift`) is permitted in sandboxed App Store apps and needs neither an entitlement nor an Accessibility grant. Good news, because an event-tap approach would not have survived.

**Check the state-file path.** The core's `write_private` (`crates/ffi/src/persist.rs`) writes the encrypted state file to a path the Swift side hands it. Make sure that path resolves inside the sandbox container. `NSHomeDirectory` and `FileManager.applicationSupportDirectory` already return the container path once sandboxed, so if Swift uses those you're fine; a hardcoded absolute path outside the container will fail closed.

**Capture exclusion is free and already correct.** `sharingType = .none` needs no entitlement, and the `COMPANION_ALLOW_CAPTURE` toggle is compiled out of release, so the TestFlight build is never screenshot-able. That also means you cannot let me drive it through screen tools once it's a release build; you'll test the shipped artifact by hand.

**Reconcile the name before step 3.** The name "OnetimePad" is now consistent across the bundle name, About panel, tray menu, and accessibility label (`productName` in `BackdropApp.swift`). Whatever name you register in App Store Connect, keep those surfaces matching it, or testers see two different product names.

Sources: [Provisioning Profiles for macOS Apps (Xojo)](https://blog.xojo.com/2025/01/30/provisioning-profiles-for-macos-apps/), [Uploading macOS Builds to App Store Connect (Xojo)](https://blog.xojo.com/2025/01/14/uploading-macos-builds-to-app-store-connect/), [Upload builds — App Store Connect Help (Apple)](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), [TN3147: Migrating to the latest notarization tool (Apple)](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool), [Meet TestFlight on Mac — WWDC21 (Apple)](https://developer.apple.com/videos/play/wwdc2021/10170/).
