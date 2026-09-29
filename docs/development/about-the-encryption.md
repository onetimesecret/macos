# App encryption and export compliance

## Current release decision

The initial TestFlight rollout excludes France from the app's intended distribution. Keep `ITSAppUsesNonExemptEncryption` set to `true`; excluding France does not change the app's use of encryption.

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

to `shell/OnetimePad-Info.plist`, then rebuild the App Store package.
