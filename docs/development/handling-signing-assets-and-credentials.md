---
# docs/development/handling-signing-assets-and-credentials.md
---

# Handling Apple signing assets and credentials

This guide classifies the files and identifiers used to sign and submit
OnetimePad. It distinguishes cryptographic secrets from operational material
that is not secret but should still stay out of the repository.

Apple's [certificate guidance](https://developer.apple.com/help/account/certificates/certificates-overview/)
sets the handling baseline:

> “Your Apple Account, authentication credentials, and related account
> information and materials (such as Apple Certificates used for distribution
> or submission to the App Store) are sensitive assets that confirm your
> identity.”

Apple also says:

> “Do not share Apple Certificates outside of your organization.”

Follow that stricter handling rule even where an artifact contains only public
key material.

## Classification

### Secrets

Possession of these values can authorize signing or account access. Never put
them in source control, issue text, chat, build logs, or untrusted storage.

| Material | Why it is secret | Storage |
| --- | --- | --- |
| Signing private keys | Authorize signatures under the corresponding Apple certificate | macOS Keychain, or an approved secrets system for CI |
| `.p12` or `.pfx` exports | Usually contain a certificate and its private key | Encrypted backup or CI secrets system |
| Export passwords | Unlock private-key exports | Separate from the export itself |
| App Store Connect API `.p8` keys | Authenticate App Store Connect API requests | Secrets system only |
| Apple Account passwords, app-specific passwords, session tokens, recovery keys, and two-factor codes | Authenticate the Apple Account | Password manager or Apple authentication flow |
| CI variables containing any of the above | Reproduce the underlying authority | Protected CI secrets |

Generating a certificate signing request (CSR) creates a private key in the
Keychain. The private key does not travel in the CSR and must not be exported
without the protections above.

### Internal operational material

These artifacts do not contain a signing private key and do not grant signing
or account access by themselves. Keep them outside the repository because they
identify the account, expire, change independently of source, or fall under
Apple's certificate-handling guidance.

| Material | Contents and exposure |
| --- | --- |
| Apple-issued `.cer` certificate | Public key, team identity, certificate subject, validity dates, and issuer; Apple says not to share certificates outside the organization |
| `.certSigningRequest` CSR | Public key and identifying fields such as the requester name or email; no private key |
| `.provisionprofile` profile | Team ID, application identifier, authorized entitlements, certificate references, UUID, and expiry; no private key |
| `scripts/local.env` | Local identity names and filesystem paths today; reserved for machine-local signing configuration and ignored by Git |
| Absolute local paths | May expose usernames and workstation layout, but confer no signing authority |
| App Store Connect SKU | Internal catalog metadata, not an authentication credential |

A distribution provisioning profile is embedded in the submitted application,
so it cannot be treated as confidential after distribution. It remains a
machine-generated, account-specific build input and does not belong in source
control.

### Public identifiers

These values are expected to be observable in an application bundle, code
signature, certificate, or App Store record. They are not authentication
secrets:

- Bundle identifier: `com.onetimesecret.pad`
- Apple Team ID
- App ID and certificate display names
- Certificate fingerprints
- Application version and build number
- Public product and publisher names

Public does not mean anonymous. Certificate subjects can contain a person's
legal name, and a local path can contain an account name. Redact those fields
when the audience does not need them.

## Repository handling

The repository's [`.gitignore`](../../.gitignore) excludes
`*.provisionprofile`, `*.p12`, `*.pem`, `*.token`, `scripts/local.env`, and
`secrets/`. Keep CSRs and `.cer` files in the same external signing-material
directory even though those two extensions are not ignored globally.

For the local manual-signing workflow:

1. Keep the signing-material directory outside the checkout and readable only
   by its owner.
2. Leave private keys in the login Keychain.
3. Point `PROVISIONING_PROFILE` at the external profile from
   `scripts/local.env`; do not copy the source profile into the repository.
4. Let the packaging script copy the profile into the assembled `.app` only
   for the distribution build.
5. Store any `.p12` backup encrypted, with its password stored separately.
6. Before publishing logs or screenshots, remove personal names, email
   addresses, absolute paths, tokens, and account screens that reveal more
   than the task requires.

## If material is exposed

The response depends on the classification:

- For a Team ID, bundle ID, fingerprint, public certificate, CSR, or
  provisioning profile, remove unnecessary copies and review the exposed
  personal or operational metadata. Exposure alone does not reveal the
  signing private key.
- For a private key, `.p12`/`.pfx` file, export password, API `.p8` key,
  Apple Account credential, or session token, treat the signing or account
  authority as compromised. Revoke or rotate the affected credential in the
  Apple Developer or App Store Connect account, replace dependent profiles or
  CI configuration, and review account activity.

Do not paste suspected secret material into a bug report. Follow the
repository's [security-reporting process](../../SECURITY.md) instead.
