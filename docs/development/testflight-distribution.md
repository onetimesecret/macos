---
# docs/development/testflight-distribution.md
---

# Distributing OnetimePad through TestFlight

Use this guide to prepare the Apple account once, then build, upload, and test
OnetimePad using the repository's SwiftPM and shell-script workflow. The upload
artifact is `dist/OnetimePad.pkg`, containing `OnetimePad.app`.

## Scope and readiness

The [packaging script](../../scripts/package-app.sh) implements
`--app-store`: it builds the release app, reserves a build number, embeds a
profile, signs the app, checks the result, and creates a signed installer
package. It does not upload the package or configure App Store Connect.

These instructions describe the source inspected on 2026-09-29, not a completed
submission. Apple account setup, acceptance of a package, and runtime behavior
must be checked on the publishing account and test Macs.

**File-access readiness is still an open check.** In the inspected source,
[FileCoordinator](../../shell/Sources/CompanionKit/FileCoordinator.swift) creates
and resolves bookmarks with `options: []`, and `withAccess` calls the body
without a security-scoped access bracket. The
[entitlements template](../../scripts/Companion.entitlements) contains sandbox,
outgoing network, and Keychain access-group entries, but no user-selected-file
or security-scoped bookmark entries. This is an implementation observation,
not a verified sandbox compatibility result. Treat file editing and reopening
files after relaunch as release gates; investigate the entitlement and bookmark
implementation if those tests fail. Packaging success does not establish that
they work.

## 1. Prepare the build Mac and account

- Use macOS with Xcode, its command-line tools, Swift, Python 3, and rustup.
  The Rust version is pinned in [rust-toolchain.toml](../../rust-toolchain.toml).
  [build-core.sh](../../scripts/build-core.sh) builds for both
  `aarch64-apple-darwin` and `x86_64-apple-darwin`.
- Confirm which Xcode installation the build will use. `build-core.sh` honors
  `DEVELOPER_DIR`; otherwise it prefers `/Applications/Xcode-beta.app` when
  present, then falls back to `xcode-select -p`. Set `DEVELOPER_DIR` explicitly
  when choosing a different installed Xcode for distribution.
- Use the intended Apple Developer Program team for the App ID, distribution
  certificates, provisioning profile, and App Store Connect record.
- Have account access for each task. Apple's
  [app-record instructions](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
  list Account Holder, App Manager, or Admin for app creation; its
  [profile instructions](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)
  list Account Holder or Admin. The
  [upload instructions](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
  also allow Developer for uploading.
- Install Apple's Transporter app for the upload step.

Run shell commands below from the repository root. Do not copy another
operator's certificate subject, Team ID, or local profile path from a discussion.
Use the values for the publishing account and this Mac.

## 2. Register the production App ID and app record

In Apple Developer's **Certificates, Identifiers & Profiles**, register an
explicit App ID for `com.onetimesecret.pad`, or confirm that it already exists
under the intended team. A suggested description is **OnetimePad - macOS**.

Apple's provisioning-profile instructions state:

> Uploading an app to App Store Connect requires an app record registered with an explicit App ID.

The production identifier is the value in
[OnetimePad-Info.plist](../../shell/OnetimePad-Info.plist). The packaging script
uses `dev.onetimesecret.pad` for `--debug`; do not use that lane for this upload.

Create or locate the app under **App Store Connect → Apps**:

| Field | Value |
| --- | --- |
| Platform | macOS |
| Name | OnetimePad, subject to availability |
| Bundle ID | `com.onetimesecret.pad` |
| Primary language | Choose the app's intended primary language |
| SKU | Suggested for a new record: `onetimesecret-pad-macos` |
| User access | Grant access to the people managing this app |

The SKU above is a suggestion, not evidence that the record exists. Reuse the
existing record if one has already been created. Apple requires the Account
Holder to accept the latest agreement before adding an app.

Do not look for App Sandbox or Keychain Sharing checkboxes in the App ID form
as a substitute for the signed entitlements. In this repository those entries
are supplied through the entitlements template and packaging script. Enable
additional portal capabilities only for a feature that actually needs them.

## 3. Prepare certificates and a distribution profile

The App Store signing lane has two distinct identities:

| Configuration | Purpose | Installed identity name used by this workflow |
| --- | --- | --- |
| `APP_STORE_CODESIGN_IDENTITY` | Sign the app | `3rd Party Mac Developer Application: …` |
| `APP_STORE_INSTALLER_IDENTITY` | Sign the installer package | `3rd Party Mac Developer Installer: …` |

In the developer portal these certificate types are named **Mac App
Distribution** and **Mac Installer Distribution**. If they are not already
available on the build Mac, create certificate signing requests in Keychain
Access, use them to request the respective certificates, and install the issued
certificates on the Mac that holds their corresponding private keys.

Check the installed identities:

```sh
security find-identity -v -p codesigning
security find-identity -v -p basic
```

Use the exact quoted application and installer identity names in the results.
A development identity or Developer ID identity is not the distribution
identity requested by this workflow. Check that both distribution identities
belong to the intended team.

Following Apple's linked profile instructions:

1. In **Profiles**, add a distribution profile of type **Mac App Store Connect**.
2. Select the explicit App ID matching `com.onetimesecret.pad`.
3. Select the application distribution certificate.
4. Give the profile a recognizable name, generate it, and download it.
5. Record its expiry and confirm that it is the profile for this team and app.

For storage, sharing, backups, and exposure handling, follow
[Handling Apple signing assets and credentials](handling-signing-assets-and-credentials.md).
Do not add certificate exports or account-specific paths to this guide.

## 4. Configure local signing

Use the App Store section of
[scripts/local.env.example](../../scripts/local.env.example) as the template.
Create `scripts/local.env` if absent; if it already exists, edit it rather than
copying over it. Set these three values:

- `APP_STORE_CODESIGN_IDENTITY`: exact application distribution identity.
- `APP_STORE_INSTALLER_IDENTITY`: exact installer distribution identity.
- `APP_STORE_PROVISIONING_PROFILE`: absolute path to the downloaded distribution
  profile outside the checkout.

The script sources `scripts/local.env` itself, and values assigned there take
precedence over inherited environment values. `DEV_*`, `LOCAL_*`, and
`APP_STORE_*` values coexist in that file; packaging selects only the requested
lane. The script rejects the former unprefixed signing variables rather than
risk applying one lane's identity or profile to another.

## 5. Confirm version and encryption information

Check `CFBundleShortVersionString` in `shell/OnetimePad-Info.plist` for the
marketing version. The App Store lane writes a decimal build number to
`CFBundleVersion` instead of the local build's version and commit string.

Apple's upload instructions explain:

> The build string is used to uniquely identify the build throughout the system.

The script takes the build number from a counter file, so each run gets a new
one without being told:

- **Location.** By default the counter is
  `onetimepad-app-store-build-number` in the git common directory
  (`git rev-parse --git-common-dir`), so every worktree of one clone reads and
  advances the same file. It is not tracked by git. Set
  `APP_STORE_BUILD_NUMBER_FILE` in `scripts/local.env` to use another path;
  outside a git checkout that variable is required.
- **Reservation.** After the Swift build succeeds, the script takes an
  exclusive lock, reads the last number, writes its successor to a temporary
  file beside the counter, and renames that file over the counter. Concurrent
  runs from different worktrees therefore get different numbers. A number is
  spent once reserved: if signing or packaging fails later, the next run takes
  the next number, so the sequence can skip values.
- **Explicit number.** `--build-number N` uses `N` instead of the counter's
  successor. If `N` is higher than the counter, the counter is raised to `N`
  and the next run continues above it. If it is not higher, the script warns
  and leaves the counter unchanged.
- **Limits.** The counter records only reservations made through it. It does
  not know what App Store Connect has received from another clone or Mac, or
  from builds numbered before the counter existed. A missing counter starts
  at 1. The script checks the number's syntax, not whether App Store Connect
  has already seen it.

The current plist sets `ITSAppUsesNonExemptEncryption` to `false` and omits
`ITSEncryptionExportComplianceCode`. This implements the interpretation of the
initial rollout's no-documentation questionnaire outcome, not a claim that the
app uses no encryption. Consult
[App encryption and export compliance](encryption-export-compliance.md) for the
selected answers, Apple's key definition, and the process for adding France.
Confirm that the answers still match the shipped app and intended distribution;
the guide does not establish the account's actual availability settings or
Apple's acceptance of a build. Resolve any compliance request rather than
changing the boolean merely to dismiss a prompt.

## 6. Build and inspect the package

Run:

```sh
scripts/package-app.sh --app-store
```

The script prints the reserved number and the counter path in its
`==> App Store build number` line and repeats the number in its final line.

When App Store Connect already has builds the counter has not seen, such as
the first run in a new clone, pass the next unused number once. For example,
if the highest build App Store Connect has is `2`:

```sh
scripts/package-app.sh --app-store --build-number 3
```

Later runs continue from `4` without the option.

This is not a dry run: the script builds the Rust and Swift artifacts, reserves
a build number, replaces `dist/OnetimePad.app`, and replaces
`dist/OnetimePad.pkg` when it reaches package creation. It neither installs the
app nor uploads it. Use only the output of a successful run; an older package
may remain after an earlier failure.

Before compiling, the script checks identity availability and the profile's
team, explicit App ID, Keychain group, selected certificate, expiry, and profile
class. After signing, it checks the app signature, build number, embedded
profile, hardened-runtime flag, sandbox/network/Keychain entitlements, and the
package signature. These are
local checks, not a substitute for Apple's validation. In particular, inspect
profile validity and certificate suitability rather than assuming the script
checks every distribution requirement.

Inspect the resulting artifacts without changing them:

```sh
plutil -extract CFBundleIdentifier raw dist/OnetimePad.app/Contents/Info.plist
plutil -extract CFBundleShortVersionString raw dist/OnetimePad.app/Contents/Info.plist
plutil -extract CFBundleVersion raw dist/OnetimePad.app/Contents/Info.plist
plutil -extract ITSAppUsesNonExemptEncryption raw dist/OnetimePad.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/OnetimePad.app
codesign -dvvv dist/OnetimePad.app
codesign -d --entitlements - --xml dist/OnetimePad.app
pkgutil --check-signature dist/OnetimePad.pkg
```

Confirm the production bundle ID, selected version/build, intended signing team
and identities, and rendered entitlements. Record the commit, version, build
number, and validation outcome with the release notes. If a check fails, correct
the input or implementation and rerun packaging; do not patch the signed bundle
and upload the old package.

## 7. Upload with Transporter

Transporter is Apple's separate macOS application for uploading builds to
App Store Connect. It is not a page in App Store Connect or a command in this
repository.

1. Install [Transporter from the Mac App Store](https://apps.apple.com/app/transporter/id1450874784).
2. Open **Transporter** from Applications.
3. Sign in with the Apple Account that has access to OnetimePad in App Store
   Connect and one of the upload roles listed in step 1 of this guide. This
   may differ from the account used to download Transporter from the Mac App
   Store. Complete any authentication prompts.
4. If Transporter offers a provider selection, choose the organization
   publishing OnetimePad.
5. Add `dist/OnetimePad.pkg` and confirm the selected provider/team.
6. Use Transporter's verification and delivery workflow. Resolve reported
   errors and retain the delivery result.
7. In **App Store Connect → OnetimePad → TestFlight**, wait for processing.
8. Check that the expected version and build number appear. Complete any
   encryption-compliance questions or other processing actions shown there.

Signing in authorizes the upload; it does not replace code signing. The
packaging script has already signed the app and installer using the configured
identities and their private keys in the Mac's Keychain.

Apple's upload instructions state:

> However, the build needs to be processed in Apple’s system before it appears in App Store Connect.

A successful Transporter delivery is therefore not yet a build available to
testers. If processing fails, inspect the App Store Connect message or email,
fix the reported issue, and run packaging again; the rerun reserves a new
build number.

## 8. Start with internal testers

Follow Apple's
[TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/):

1. Provide the beta description, feedback email, and **What to Test** information.
2. Create an internal testing group, assign the processed build, and add eligible
   App Store Connect users with access to the app.
3. Have testers install TestFlight on their Macs and accept the invitation.
4. Install from TestFlight and verify the version/build inside OnetimePad.

The overview describes up to 100 internal testers and up to 10,000 external
testers. For external testing, create an external group, complete the requested
beta review/contact information and any review access instructions, and submit
the first build for review. Subsequent builds may not require a full review.
Invite external testers only once the build is approved and the internal checks
below are complete. Builds are available for testing for up to 90 days.

## 9. Check the installed TestFlight build

Use disposable test content and a dedicated test account or Mac for initial
qualification. These are proposed release checks, not assertions that the
current implementation passes:

- Launch, quit, and relaunch; verify the expected version and build.
- Save an API token, relaunch, and confirm that the app can use it.
- Create a page, save, relaunch, and verify the expected content is restored.
- Run a conceal operation with test content and check the resulting link.
  This step sends the test content to the configured service.
- Test the global summon shortcut, menu bar item, Settings, and editor window.
- Open a disposable file, edit, Save, and Save As. Relaunch and reopen it;
  repeat after a rename or move. Investigate the file-access gap noted above
  before treating file editing as ready.
- If device sync is included in the beta, test pairing and synchronization
  between test installations.
- Test an update from one TestFlight build to the next, including token use and
  saved content. Do not infer migration behavior from a clean installation.

Record failures with the build number and reproduction steps. See the
[signing-assets guide](handling-signing-assets-and-credentials.md) before
sharing diagnostic output. Repeat packaging, upload, processing, and internal
qualification for the next build; account and certificate setup need repeating
only when those inputs change or expire.
