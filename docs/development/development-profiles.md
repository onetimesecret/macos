---
# docs/development/development-profiles.md
---

# Creating development profiles for the local and dev lanes

The steps for the two development signed lanes. The App Store lane has its own guide,
[Distributing OnetimePad through TestFlight](testflight-distribution.md).

| Lane  | Entry point          | Bundle identifier             | App ID the profile must authorize    |
| ----- | -------------------- | ----------------------------- | ------------------------------------ |
| local | `scripts/install.sh` | `dev.onetimesecret.pad`       | `TEAMID.dev.onetimesecret.pad`       |
| dev   | `scripts/dev.sh`     | `dev.onetimesecret.pad.debug` | `TEAMID.dev.onetimesecret.pad.debug` |

`TEAMID` is the ten character Team ID, shown under Membership details at
<https://developer.apple.com/account>.

Create one profile per lane against two explicit App IDs. One profile against
the wildcard App ID `TEAMID.dev.onetimesecret.*` also works today, and the
[profile validator](../../scripts/validate-provisioning-profile.py) accepts a
trailing wildcard for a development profile; the next section says why
explicit is the default here.

## Explicit or wildcard

| Question | If yes | If no |
| --- | --- | --- |
| Does the build need a capability that is switched on per App ID (push, iCloud, App Groups, Sign in with Apple, associated domains)? | Explicit is required; a wildcard App ID cannot carry them | Either works |
| Should the development build rehearse the shipping one? | Explicit, so a missing capability fails locally and not at the TestFlight upload | Either works |
| Are there many throwaway bundle identifiers with no capabilities? | Wildcard saves registering each | Explicit costs little |

For OnetimePad:

- Today either works. [Companion.entitlements](../../scripts/Companion.entitlements)
  asks for the sandbox, outgoing network, and a Keychain access group, and
  none of those is an App ID capability.
- The first feature that needs push, iCloud, or App Groups makes a wildcard
  profile unusable, and this setup is then redone under explicit ids.
- The App Store lane's `com.onetimesecret.pad` must be explicit. An explicit
  `dev.onetimesecret.pad` keeps the installed copy's signing the same shape
  as what ships.
- The cost is two registrations once, and two profiles to renew each year
  where a wildcard has one.

## Where to go

Every page below is in **Certificates, Identifiers & Profiles** and needs a
signed in Apple Developer account.

| What                  | Page                                                              |
| --------------------- | ----------------------------------------------------------------- |
| Certificates          | <https://developer.apple.com/account/resources/certificates/list> |
| Identifiers (App IDs) | <https://developer.apple.com/account/resources/identifiers/list>  |
| Devices               | <https://developer.apple.com/account/resources/devices/list>      |
| Profiles              | <https://developer.apple.com/account/resources/profiles/list>     |

Apple's own instructions for each step:

- [Create developer certificates](https://developer.apple.com/help/account/certificates/create-developer-certificates/)
- [Register an App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id/)
- [Register a single device](https://developer.apple.com/help/account/devices/register-a-single-device/)
- [Create a development provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/)

## Steps

1. **Certificate.** Confirm an Apple Development identity is installed:

   ```sh
   security find-identity -v -p codesigning
   ```

   If none is listed, create one on the
   [Certificates](https://developer.apple.com/account/resources/certificates/list)
   page and install it on this Mac.

2. **App ID.** On the
   [Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   page, press the add button beside the Identifiers heading, then:

   1. On **Register a new identifier**, leave **App IDs** selected and
      continue.
   2. On the type screen, choose **App** and continue.
   3. Enter a description, for example `OnetimePad Local`.
   4. Under Bundle ID choose **Explicit** and enter `dev.onetimesecret.pad`.
   5. Leave every capability unchecked, continue, and register.

   Repeat with the description `OnetimePad Dev` and the bundle identifier
   `dev.onetimesecret.pad.debug`. For the wildcard route, choose **Wildcard**
   once and enter `dev.onetimesecret.*`.

3. **This Mac.** Read its Provisioning UDID:

   ```sh
   system_profiler SPHardwareDataType | grep 'Provisioning UDID'
   ```

   Register it as a macOS device on the
   [Devices](https://developer.apple.com/account/resources/devices/list) page.
   Skip this when the Mac is already listed.

4. **Profile.** On the
   [Profiles](https://developer.apple.com/account/resources/profiles/list)
   page, add a profile of type **macOS App Development**. Select the App ID
   from step 2, the certificate from step 1, and the Mac from step 3. With
   explicit App IDs, repeat for the second one. Name them:

   | Lane | Profile name | Downloaded file |
   | --- | --- | --- |
   | local | `OnetimePad Local` | `OnetimePad_Local.provisionprofile` |
   | dev | `OnetimePad Dev` | `OnetimePad_Dev.provisionprofile` |

   The portal names the download after the profile, with each space turned
   into an underscore, so these names produce the filenames the environment
   files expect. The name is a label only: the validator reads the profile's
   contents, and the environment file can point at any path.

5. **Download.** Save each profile into its lane's environment directory,
   outside the checkout:

   ```text
   ~/.local/appledev/CompanionApp/environments/local/OnetimePad_Local.provisionprofile
   ~/.local/appledev/CompanionApp/environments/dev/OnetimePad_Dev.provisionprofile
   ```

   A wildcard profile can sit in either directory; both lanes then name the
   same file.

6. **Point the lanes at it.** In `local/.env` and `dev/.env` under the same
   `environments` directory, set the identity and the profile path. The
   names are the same in both files; the directory says which lane they
   belong to. The template is
   [environments/example/.env.example](../../environments/example/.env.example).

   `local/.env`:

   ```sh
   CODESIGN_IDENTITY="Apple Development: Name (TEAMID)"
   PROVISIONING_PROFILE="$HOME/.local/appledev/CompanionApp/environments/local/OnetimePad_Local.provisionprofile"
   ```

   `dev/.env`:

   ```sh
   CODESIGN_IDENTITY="Apple Development: Name (TEAMID)"
   PROVISIONING_PROFILE="$HOME/.local/appledev/CompanionApp/environments/dev/OnetimePad_Dev.provisionprofile"
   ```

7. **Check.** Run the lane. Before it compiles, `scripts/package-app.sh`
   validates the profile's team, App ID, Keychain access group, certificate,
   expiry, profile class, and this Mac's Provisioning UDID, and names whichever
   one is wrong.

   ```sh
   scripts/install.sh --no-launch
   scripts/dev.sh --no-launch
   ```

To read what a downloaded profile authorizes without building:

```sh
security cms -D -i OnetimePad_Local.provisionprofile \
  | plutil -extract Entitlements xml1 -o - -
```

## When a profile stops working

A development profile expires after a year, and it stops matching when the
certificate is reissued or the build moves to a Mac it does not list. Edit the
profile on the
[Profiles](https://developer.apple.com/account/resources/profiles/list) page,
download it again, and replace the file in the environment directory.

For storage, sharing, and exposure handling, follow
[Handling Apple signing assets and credentials](handling-signing-assets-and-credentials.md).
