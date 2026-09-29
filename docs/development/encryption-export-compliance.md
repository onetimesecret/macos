---
# docs/development/encryption-export-compliance.md
---

# App encryption and export compliance

OnetimePad is a macOS app for writing notes and sharing sensitive text through one-time links. It uses encryption for locally stored content, device synchronization and pairing, and HTTPS communication with the Onetime Secret service.

## Current release decision

The initial TestFlight rollout excludes France from the app's intended distribution.
The release declaration in [OnetimePad-Info.plist](../../shell/OnetimePad-Info.plist)
is `ITSAppUsesNonExemptEncryption = false`, with
`ITSEncryptionExportComplianceCode` absent. This is the interpretation adopted
for the questionnaire outcome below, not a claim that OnetimePad uses no
cryptography or a determination of exemption from all export laws.

### Questionnaire answers and result

The publishing operator's App Store Connect screenshots supplied on 2026-09-29
show these selections:

- **Algorithms:** select “Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system”.
- **Proprietary or non-standard algorithms:** leave unchecked.
- **Distribution in France:** select **No** for this rollout.

Apple's resulting dialog states:

> Based on your answers, you don't need to upload any documents.

The operator observed that clicking **OK** closed the dialog without adding an
entry to **App Encryption Documentation**, and that **Upload** reopened the
questionnaire. That is consistent with a no-documentation outcome: there is no
document to upload or approved-document code to copy on this path. An empty
section alone does not indicate a failed upload.

These screenshots establish the questionnaire's response to those answers,
not Apple's acceptance of a binary or the account's actual geographic
availability. Confirm that the answers match the shipped app and intended
distribution before each submission. Reassess if the algorithms or distribution
change, including adding France.

### What the plist boolean means

Apple's [`ITSAppUsesNonExemptEncryption` reference](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)
defines the `NO` value as follows:

> Set the value for this key to `NO` in your app’s `Information Property List` file to indicate that your app—including any third-party libraries you link against—either uses no encryption, or only uses encryption that’s exempt from export compliance requirements, as described in Overview of export compliance.

The key concerns **non-exempt encryption**, not the mere presence of encryption.
Using `ring` or `rustls` outside Apple's operating system does not, by itself,
establish that the value must be `true`. Excluding France does not remove
cryptography from the app; the current `false` declaration follows the
interpretation of the completed questionnaire above.

For this rollout, use:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Leave `ITSEncryptionExportComplianceCode` absent. Do not add an empty string,
`[]`, or a placeholder code. Apple's code is relevant when documentation is
required and approved, as described in the France workflow below.

### Rebuilding after error 90592

The reported submission had `ITSAppUsesNonExemptEncryption = true` with no
`ITSEncryptionExportComplianceCode`, and Transporter reported **Invalid Export
Compliance Code (90592)**. Its displayed `[]` was not an array in the plist;
the key was absent.

After correcting the source plist, rebuild using the
[TestFlight packaging procedure](testflight-distribution.md#6-build-and-inspect-the-package)
with an unused build number. Inspect the rebuilt app's plist, then verify and
deliver the new package through Transporter. Do not edit an already signed
bundle. A successful new validation is still needed to establish that 90592 is
resolved; if it persists, investigate the app's export-compliance record with
Apple rather than inventing a code or toggling the boolean to suppress it.

### France requirement

Apple's [export-compliance reference](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/) states:

> “French encryption declaration form is only required if you’re distributing your app on the App Store in France.”

Do not upload a blank or self-signed ANSSI application to satisfy Apple's request. If France is added later, complete the authority-issued documentation process below before submitting the applicable build for review.

## Technical information

The current implementation inventory is based on the shipping source:

- `crates/core/src/persist.rs` and `crates/ffi/src/lib.rs`: ChaCha20-Poly1305
- `crates/ffi/src/gop.rs`: HKDF-SHA256
- `crates/ffi/src/pairing.rs`: SHA-256, X25519, Ed25519, and HKDF-SHA256
- `crates/transport/src/lib.rs`: TLS through `rustls`

The Rust implementation uses the `ring` and `rustls` libraries for:

- Encrypted local state, drafts, and ledger
- Encrypted device synchronization
- Device pairing and signatures
- HTTPS communication

## France distribution (deferred)

Before enabling distribution in France, file the applicable declaration or authorization request with France's ANSSI.

### 1. Download the official combined form

[Déclaration et demande d’autorisation d’opérations relatives à un moyen de cryptologie — PDF](https://cyber.gouv.fr/documents/330/crypto_declaration-demande_autorisation_operations_annexe1_v2.pdf)

ANSSI’s instructions:

[Contrôle réglementaire sur la cryptographie : les formulaires](https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/)

The form covers both declaration and authorization cases. Which boxes apply depends on the declaring legal entity, its location, and the intended supply/import/export operation. Do not select an authorization category solely because Apple uses the word “approval.”

### 2. Prepare the filing

The declarant will need to provide information only the organization can supply:

- Legal entity name and address
- Authorized signatory
- Supplier or first-importer status
- Commercial operation and distribution details
- Product name: **OnetimePad**
- Publisher/brand: **Onetime Secret**
- Platform: **macOS**
- Bundle identifier: `com.onetimesecret.pad`

Use the technical information above when preparing the supporting documentation.

### 3. Submit it to ANSSI

ANSSI’s current instructions require an email to:

`controle@ssi.gouv.fr`

Subject:

```text
[formalités] Onetime Secret – OnetimePad
```

Attach:

1. The completed, signed, scanned form
2. The completed electronic PDF saved with its form data
3. Supporting technical documentation

ANSSI’s exact wording is:

> “Ajouter en pièces jointes : le formulaire complété signé scanné, le formulaire électronique complété sauvegardé, la documentation requise.”

### 4. Wait for the ANSSI-issued document

ANSSI distinguishes between:

- **Attestation de déclaration** — confirms the supplier fulfilled the declaration requirement.
- **Attestation de classement d’un moyen de cryptologie** — official “grand public” classification, when such classification was requested and accepted.
- Export authorization documents, where applicable.

ANSSI describes the first as:

> “Attestation de déclaration : Elle prouve que le fournisseur s’est acquitté de son obligation déclarative.”

The exact ANSSI response required by Apple may depend on how the filing is classified. Because Apple says **“French encryption declaration approval form,”** upload the authority-issued attestation or approved/stamped document returned by ANSSI—not merely the blank or self-signed application.

### 5. Upload the ANSSI response to Apple

Apple's [documentation upload workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation) states:

> “This should be completed before submitting a build for review on either App Review or TestFlight App Review.”

After receiving the ANSSI document, follow Apple's workflow:

1. Open **App Store Connect → Apps → OnetimePad**.
2. Select **App Information**.
3. Next to **App Encryption Documentation**, click the add button (**+**) and answer the questions.
4. When prompted, click **Choose File** and select the ANSSI-issued PDF.
5. Click **Save**.

Apple describes the result of an approved submission as follows:

> “Once your documentation is approved, Apple will provide you a key value. You must enter this value in Xcode to avoid answering encryption questions with each app submission.”

After Apple approves it, copy the compliance code Apple provides and add:

```xml
<key>ITSEncryptionExportComplianceCode</key>
<string>APPLE_PROVIDED_CODE</string>
```

to `shell/OnetimePad-Info.plist`. Reassess `ITSAppUsesNonExemptEncryption` for
that submission under Apple's key definition above; do not carry forward the
initial no-France declaration without checking the new requirements. Then
rebuild the App Store package.
