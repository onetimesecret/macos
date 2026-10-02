# docs/spec/feature/json5-settings/assessment.md
---
documentation_status: needs-review
---

# JSON5-backed settings assessment

## Status

This document assesses the work required to replace eligible `UserDefaults` preferences with a file-backed settings system. It records verified repository behavior, implementation constraints, recommended architecture, and unresolved decisions. It is not an accepted architecture decision or a completed feature specification.

## Summary

Settings are a larger migration than keymaps. The keymap is an application-read, launch-time configuration file. Settings have multiple writers and runtime owners, trigger side effects, and use several persistence mechanisms.

The proposed design makes a sparse user settings file the sole persistent source of truth for eligible settings. Bundled defaults supply omitted values. Existing `UserDefaults` values participate only in a one-time import and do not remain as a permanent parallel settings store.

Before implementation, an accepted decision must establish the persistence boundary, complete field inventory, migration behavior, file-write ownership, reload behavior, and treatment of window geometry and pinning.

## Decision-record conflicts

ADR-0012 contains the exact statement:

> “**Settings** remain in `UserDefaults` (never secrets).”

— `docs/adr/0012-framing-threat-boundary-and-persistence-model.md:96`

ADR-0012 is marked `Status: proposed` and `documentation_status: needs-review` at `docs/adr/0012-framing-threat-boundary-and-persistence-model.md:1-8`. It therefore documents a proposal rather than an accepted project guarantee. A settings-file decision conflicts with that proposal and must resolve the conflict through an accepted amendment, replacement, or successor decision.

ADR-0020 separately says:

> “The only durable trace of the mode is a `UserDefaults` presentation preference.”

— `docs/adr/0020-a-day-is-a-projection-of-live-pages.md:43-45`

ADR-0020 is also proposed. The settings-file decision must explicitly replace or amend this storage statement if the day-mode preference moves into the file.

ADR-0011 requires boundary snapping to be a persisted setting in the local form factor's settings domain, but does not require `UserDefaults` specifically:

> “The snap is a persisted setting, **enabled by default**, in the local form factor's settings domain.”

— `docs/adr/0011-ttl-choices.md:140-145`

## Current persistence ownership

| Area | Current owner and persistence | Runtime behavior | UI status |
| --- | --- | --- | --- |
| General, editor, code, and navigation preferences | `PageModel` using individual `UserDefaults` keys | Property observers save immediately; some invalidate rendering, apply typography, update the core, or reconcile selection | Mostly exposed |
| Connection server, share domain, and organization extid | `PageModel` using `UserDefaults` after core validation | Saved as one connection operation only after the core accepts the configuration | Exposed through draft fields and an explicit Save action |
| Connection API token | Credential path through FFI and the macOS Keychain | `nil` retains the token and an empty string deletes it | Write-only; never file-backed |
| Sync enabled | `SyncController` using `UserDefaults` | Enabling starts configuration and attachment; disabling detaches and stops the loop | Exposed |
| Sync endpoint overrides | `SyncController` reading `UserDefaults` | Resolved when sync begins | Not exposed |
| Backdrop pinning | `BackdropModel` using `UserDefaults` | Window level, Space behavior, mouse handling, and frame follow the value | Action exists outside conventional settings fields |
| Backdrop geometry | `BackdropGeometry` encoded as JSON `Data` in `UserDefaults` | Persisted after committed movement, reset, display reclamping, and zoom changes | Reset action is exposed |
| Launch at login | `SMAppService.mainApp` | Registration belongs to the installed application bundle | Exposed |
| Capture allowance | Process environment and session state | Deliberately resets to capture exclusion at each ordinary launch | Conditionally exposed; not persisted |
| Keymap | Optional user file over a bundled default | Resolved once during `PageModel` initialization | File-only and already migrated |

Primary source locations:

- `shell/Sources/CompanionKit/PageModel.swift:642-904`
- `shell/Sources/CompanionKit/PageModel.swift:1358-1436`
- `shell/Sources/CompanionKit/PageModel.swift:4696-4733`
- `shell/Sources/CompanionKit/SyncController.swift:4-43`
- `shell/Sources/CompanionKit/SyncController.swift:83-91`
- `shell/Sources/CompanionKit/SyncController.swift:147-208`
- `shell/Sources/OnetimePad/BackdropModel.swift:73-169`
- `shell/Sources/OnetimePad/BackdropModel.swift:719-793`
- `shell/Sources/OnetimePad/BackdropGeometry.swift:99-160`
- `shell/Sources/CompanionKit/SettingsSections.swift:5-42`
- `shell/Sources/CompanionKit/SettingsSections.swift:62-70`
- `shell/Sources/CompanionKit/SettingsSections.swift:451-541`
- `shell/Sources/CompanionKit/SyncSettingsSection.swift:3-24`

## Settings inventory

The configuration contract requires a field-level inventory containing the old key, new path, default, validation rule, runtime effect, UI exposure, and migration behavior.

Verified persisted candidates are:

| Legacy key | Current owner | Notes |
| --- | --- | --- |
| `floatsOnTop` | `PageModel` | Legacy panel behavior; the current backdrop deliberately uses `restingPinned` instead |
| `wrapsLines` | `PageModel` | Also changed by the editor wrap command |
| `showsVersionsInMenu` | `PageModel` | Presentation-only |
| `syntaxHighlightingEnabled` | `PageModel` | Invalidates quiet rendering caches |
| `previewRendering` | `PageModel` | Enum; invalid values currently fall back to `allPages` |
| `languageDetectionEnabled` | `PageModel` | Development-only UI in release builds |
| `automaticallyFencePastes` | `PageModel` | Dormant unless language detection is also enabled |
| `fontFamily` | `PageModel` | Trimmed; unavailable names remain stored and use a runtime fallback |
| `codeFontFamily` | `PageModel` | Trimmed; unusable names remain stored and use a runtime fallback |
| `fontSize` | `PageModel` | Normalized through `InkStyle.Typeface` |
| `snapsToBoundaries` | `PageModel` | Sent to the core at initialization and on changes |
| `showsTimeUnits` | `PageModel` | Enabling may reconcile the selected page |
| `showsPagesDownSide` | `PageModel` | Retired: placement now follows `showsTimeUnits`, and the stored key is removed at launch; do not migrate it |
| `stampFormatShort` | `PageModel` | Empty is a valid stored value meaning use the standard pattern |
| `stampFormatFine` | `PageModel` | Empty is a valid stored value meaning use the standard pattern |
| `connection.serverURL` | `PageModel` | Persists only after core validation succeeds |
| `connection.shareDomain` | `PageModel` | Non-secret connection configuration |
| `connection.extid` | `PageModel` | Non-secret organization identifier |
| `sync.enabled` | `SyncController` | Off by default; construction is deliberately inert |
| `sync.relayURL` | `SyncController` | No derived fallback exists |
| `sync.authorizeURL` | `SyncController` | Derived from the connection server when absent |
| `sync.tokenURL` | `SyncController` | Derived from the connection server when absent |
| `sync.clientID` | `SyncController` | Has a conventional fallback |
| `restingPinned` | `BackdropModel` | Current backdrop pinning behavior |
| `backdrop.geometry` | `BackdropGeometry` | Existing encoded shape includes a legacy decoding path |

`floatsOnTop` requires an explicit retain, migrate, or remove decision. It is still initialized and writable in `PageModel`, but current backdrop behavior uses `restingPinned` instead (`shell/Sources/CompanionKit/PageModel.swift:642-650`; `shell/Sources/OnetimePad/BackdropModel.swift:73-87`).

## Persistence boundary

### File-backed settings

The eligible settings inventory becomes a sparse user override over bundled defaults. The accepted decision identifies each eligible field explicitly rather than treating every Settings-window control as file-backed by implication.

### Excluded state

The following values remain outside the settings file:

- API tokens and other Keychain credentials.
- Encrypted page, draft, and ledger state.
- `SMAppService` launch-at-login registration.
- `COMPANION_ALLOW_CAPTURE` and the session-only capture opt-out.
- Keymap bindings, which remain in their dedicated file.
- Sync authentication and pairing state.
- Other transient runtime state.

The API token remains absent from the file schema rather than existing as a redacted or ignored field.

### Unresolved classification

Backdrop geometry and pinning require a decision between:

- user configuration that belongs in the settings file; or
- local window state that remains in a separate persistence mechanism.

The decision applies independently to geometry and pinning. Geometry already carries compatibility behavior for the legacy `minEditorHeight` representation (`shell/Sources/OnetimePad/BackdropGeometry.swift:116-150`).

## Proposed file model

```text
bundled default-settings.json
          +
~/Library/Application Support/<resolved-bundle-id>/settings.json
          ↓
constrained JSON parsing and schema validation
          ↓
typed raw override + effective SettingsSnapshot
          ↓
SettingsStore and runtime consumers
```

The user path derives from `FormFactor.configurationDirectory`. This preserves the existing release/development split:

- App Store release: `com.onetimesecret.pad`;
- local release: `dev.onetimesecret.pad`;
- development: `dev.onetimesecret.pad.debug`.

The identifiers and configuration directory are defined at `shell/Sources/CompanionKit/FormFactor.swift:170-233` and `shell/Sources/CompanionKit/FormFactor.swift:365-399`.

A representative shape is:

```json5
{
  "schema_version": 1,

  "editor": {
    "wrap_lines": true,
    "font_family": "Menlo",
    "font_size": 13,
  },

  "code": {
    "font_family": "Menlo",
    "syntax_highlighting": true,
    "preview_rendering": "all_pages",
    "language_detection": false,
    "automatic_paste_fencing": false,
  },

  "navigation": {
    "organization": "slots",
    "placement": "bottom",
    "snap_deadlines_to_boundaries": true,
    "stamp_format": {
      "short": "HH:mm",
      "fine": "HH:mm:ss",
    },
  },

  "connection": {
    "server_url": "https://eu.onetimesecret.com",
    "share_domain": "",
    "organization_extid": "",
  },

  "sync": {
    "enabled": false,
    "relay_url": "wss://relay.example",
    "authorize_url": "https://example.com/oauth/authorize",
    "token_url": "https://example.com/oauth/token",
    "client_id": "onetime-companion",
  },
}
```

This shape is illustrative until the field inventory and naming contract are accepted.

## File syntax

The existing keymap parser supports JSON with two JSON5 conveniences:

- line and block comments;
- trailing commas.

It does not implement full JSON5. This limitation is explicit in:

- `shell/Sources/CompanionKit/Keymap/KeymapFile.swift:3-15`
- `docs/development/keymap-format-and-dispatch.md:12-16`

The settings format therefore requires one explicit choice:

1. The format reuses the constrained JSON-with-comments parser and documents only those two extensions.
2. The format implements full JSON5 and establishes the additional dependency and syntax contract.

Reusing the existing constrained parser is the smaller repository-consistent design. The format must not be described as full or strict JSON5 if it retains that parser.

## Configuration contract

The accepted settings decision defines:

- the complete set of file-backed fields;
- the values excluded from the file;
- whether geometry and pinning are configuration or local window state;
- the constrained-JSON or full-JSON5 syntax contract;
- schema-version requirements;
- bundled-default and user-override precedence;
- one-time legacy import behavior;
- whole-file versus field-local failure behavior;
- unknown-section and unknown-field behavior;
- external-edit and reload behavior;
- stale-write and concurrent-edit behavior;
- sparse override and reset semantics;
- downgrade and forward-compatibility behavior.

The keymap provides a precedent but does not decide the settings policy. Its behavior is:

- structurally invalid files and unsupported schema versions are rejected as a whole;
- invalid individual bindings are dropped while valid siblings remain active;
- an invalid user override leaves the bundled default active.

See `docs/development/keymap-format-and-dispatch.md:106-126` and `shell/Sources/CompanionKit/Keymap/Keymap.swift:312-354`.

## Typed settings model

SwiftUI views and AppKit controllers do not consume untyped `[String: Any]` values.

The settings subsystem separates:

- the sparse raw user override;
- the bundled default document;
- structured diagnostics;
- the resolved immutable snapshot;
- update and reset operations;
- runtime application of accepted changes.

Typed sections cover at least editor, code, navigation, connection, sync, and any accepted window settings.

Validation covers:

- exact supported `schema_version` values;
- booleans without coercion;
- known enum values;
- finite font sizes and their range behavior;
- font-family trimming while retaining unavailable names;
- connection server requirements;
- endpoint-specific sync URL schemes and completeness;
- client-ID empty and trimming behavior;
- stamp-pattern semantics, including valid empty patterns;
- unknown sections and fields;
- cross-field effects.

### Cross-field behavior

Automatic paste fencing currently remains storable while language detection is disabled. Runtime activation requires both values (`shell/Sources/CompanionKit/InkEditorView.swift:634-636`, `shell/Sources/CompanionKit/InkEditorView.swift:786-790`). The schema preserves this dormant-setting behavior unless an accepted decision deliberately changes it.

### Connection validation

Connection configuration is persisted only after the core accepts it. A rejected server URL does not modify the stored file. The existing behavior is at `shell/Sources/CompanionKit/PageModel.swift:4698-4714`.

The API token and non-secret connection fields require a defined transaction outcome when one persistence operation succeeds and the other fails.

### Sync validation

Sync validation distinguishes among:

- relay WebSocket URL requirements;
- authorization HTTPS URL requirements;
- token HTTPS URL requirements;
- client-ID requirements;
- an absent relay, which remains meaningful and does not acquire an invented fallback.

The absence of a relay fallback is explicit at `shell/Sources/CompanionKit/SyncController.swift:4-33`.

## Settings store and runtime ownership

A shared `SettingsStore` replaces independent writes from `PageModel`, `SyncController`, and `BackdropModel` for migrated fields.

The store owns both the sparse override and the effective snapshot. A normal update changes an override value. A reset removes the corresponding override so the bundled default resumes control.

Runtime application follows a two-phase lifecycle:

1. Files are parsed, validated, and resolved into an immutable snapshot.
2. Models are constructed from the snapshot without executing property-observer side effects.
3. Runtime consumers are attached.
4. Side-effecting services start at their existing lifecycle points.

This separation preserves existing behavior in which initialization reads persisted values without property observers. It also preserves the delayed sync start: `SyncController.init` is inert even when sync is enabled, and `start()` runs after page restoration (`shell/Sources/CompanionKit/SyncController.swift:189-208`).

Settings changes apply through explicit runtime consumers rather than by hydrating live models through unrelated public setters. Effects include:

- typography application and quiet-render invalidation;
- syntax and preview-render invalidation;
- grace-snap core handoff;
- selection reconciliation for navigation mode;
- connection validation and application;
- sync start and stop;
- backdrop window updates.

## UI writes and external edits

The recommended write model is canonical sparse-file serialization with atomic replacement. It does not preserve comments, whitespace, or key ordering.

Canonical writing is smaller than a token- or range-aware JSON5 editor, but it still requires conflict behavior. Without conflict detection, an external edit made after application startup can be overwritten by an unrelated Settings UI change.

The file-write contract defines:

- serialized writes;
- configuration-directory creation;
- a temporary file and same-directory atomic replacement;
- file permissions;
- stale-content detection or pre-write rereading;
- behavior when the existing file is malformed;
- treatment of unknown keys during rewriting;
- behavior when replacement fails;
- whether external edits take effect at restart, explicit reload, or through file watching.

An invalid hand-edited file is not silently replaced by a UI write. Recovery requires an explicit policy, such as refusing the write with a diagnostic, reloading a repaired file, or offering a deliberate reset.

The keymap does not establish this behavior because the application never writes it and resolves it only once during `PageModel` initialization (`shell/Sources/CompanionKit/Keymap/Keymap.swift:266-309`).

## Legacy migration

Legacy defaults participate in a one-time import, not in normal precedence.

```text
Normal resolution:
bundled defaults < user override

One-time import before normal resolution:
legacy UserDefaults → sparse user override
```

Migration behavior is:

1. When no settings file exists and migration is incomplete, explicitly present eligible legacy values are read.
2. Imported values are converted through their existing semantic decoders and normalizers.
3. Only explicitly stored values are written to the sparse override.
4. The settings file is replaced atomically.
5. Migration is marked complete only after successful replacement, or after a defined no-values result.
6. Migrated fields no longer read from or write to `UserDefaults` during normal operation.
7. Old defaults remain untouched for a defined rollback window.

The migration marker prevents stale defaults from being re-imported if a migrated user later deletes `settings.json`. With migration complete and no user file, bundled defaults apply.

An existing malformed user file is treated as a user file, not as permission to overwrite it with migrated defaults. Failed writes leave migration incomplete and preserve a defined recoverable behavior.

### Presence semantics

Missing and explicitly stored values are distinct. Migration does not materialize every effective default. Existing tests rely on absence remaining absence for several settings.

### Navigation compatibility

Navigation placement is no longer stored. Settings offers two layouts, Tabs (bottom) and Timeline (side), and `showsPagesDownSide` is a computed property that returns `showsTimeUnits`. `PageModel` removes any stored `showsPagesDownSide` value at initialization, so a settings file must not carry or migrate that key.

### Geometry compatibility

Geometry migration decodes the existing `Data` blob through `BackdropGeometry`. The decoder accepts both the current `height` field and the legacy `minEditorHeight` representation (`shell/Sources/OnetimePad/BackdropGeometry.swift:116-150`).

### Sync compatibility

The migration imports an explicitly stored relay URL without inventing one. Authorization URL, token URL, and client ID preserve their existing derived defaults when no override was explicitly stored.

## Resource placement and packaging

| Artifact | Location |
| --- | --- |
| Bundled default in the source tree | `shell/Sources/CompanionKit/Resources/default-settings.json` |
| Bundled default in the assembled application | `Contents/Resources/default-settings.json` |
| App Store release user override | `~/Library/Application Support/com.onetimesecret.pad/settings.json` |
| Local release user override | `~/Library/Application Support/dev.onetimesecret.pad/settings.json` |
| Development user override | `~/Library/Application Support/dev.onetimesecret.pad.debug/settings.json` |

The bundled file is processed as a SwiftPM resource and copied explicitly by `scripts/package-app.sh`. The assembled application does not rely on SwiftPM's generated resource bundle. The existing keymap packaging behavior is visible at:

- `shell/Package.swift:27-32`
- `scripts/package-app.sh:171-187`
- `shell/Sources/CompanionKit/Keymap/Keymap.swift:245-263`
- `shell/Tests/CompanionKitTests/BundledKeymapTests.swift:200-236`

The loader supports `Bundle.main` in the packaged application and the SwiftPM resource-bundle layout used by `swift run` and tests without using a resource accessor that traps when the bundle is missing.

Tests receive an injected override URL or configuration directory and never read the machine owner's settings file.

## File-only settings

Initial file-only settings may include existing non-UI configuration rather than introducing speculative keys:

- sync relay URL;
- sync authorization URL;
- sync token URL;
- sync client ID;
- retained `floatsOnTop`, if support continues;
- retained debug-only language-detection preferences, subject to release policy;
- geometry or pinning only if classified as configuration.

Each file-only field has a documented type, default, validation rule, runtime effect, UI visibility policy, and test proving delivery to its runtime consumer.

## Validation coverage

Acceptance coverage includes:

- comments and trailing commas in the supported constrained syntax;
- malformed-file rejection;
- unsupported and malformed schema versions;
- unknown section and field behavior;
- type, enum, finite-number, bounds, and URL validation;
- bundled-default and sparse-user-override resolution;
- deterministic resolution independent of dictionary ordering;
- update and reset/removal semantics;
- canonical-write conflict behavior;
- failed and malformed-file recovery behavior;
- one-time migration for every eligible legacy key;
- idempotent migration;
- migration failure without premature completion;
- no-value migration completion;
- deleted-file behavior after completed migration;
- legacy navigation compatibility;
- current and legacy geometry decoding;
- malformed user-file fallback without destructive overwrite;
- release/development path isolation;
- bundled resource presence under SwiftPM and in the packaged application;
- UI updates reaching both the file and runtime owner;
- delayed sync startup after state restoration;
- file-only sync endpoints reaching `SyncEndpoints.resolve`;
- absence of an invented relay endpoint;
- connection rejection before file persistence;
- absence of the API token from the schema and serialized file;
- invalid settings causing no sync attachment, core mutation, or window mutation;
- stale external edits not being silently overwritten.

Existing behavior tests are adapted rather than discarded, including:

- `shell/Tests/CompanionKitTests/AutomaticPasteFencingSettingTests.swift`
- `shell/Tests/CompanionKitTests/GraceSnapTests.swift`
- `shell/Tests/CompanionKitTests/PageModelPreviewRenderingTests.swift`
- `shell/Tests/CompanionKitTests/StampFormatSettingTests.swift`
- `shell/Tests/CompanionKitTests/SyncOffSwitchTests.swift`
- `shell/Tests/CompanionKitTests/TimeUnitModeTests.swift`
- `shell/Tests/CompanionKitTests/TypefaceTests.swift`
- `shell/Tests/CompanionKitTests/VersionDisplaySettingTests.swift`
- `shell/Tests/CompanionKitTests/WrapTests.swift`
- `shell/Tests/CompanionKitTests/FormFactorTests.swift`
- `shell/Tests/OnetimePadTests/BackdropGeometryTests.swift`
- `shell/Tests/OnetimePadTests/SettingsTabTests.swift`

## Recommended delivery sequence

### Decision and inventory

The persistence decision, exact field inventory, syntax contract, invalid-input behavior, unknown-key policy, reload behavior, and conflict behavior are settled before implementation.

### Pure settings foundation

The raw override, typed snapshot, validation, diagnostics, sparse merge, atomic writer, and reset semantics exist without model integration.

### Migration and packaging

The one-time importer, durable migration marker, navigation and geometry compatibility, release/development isolation, and resource packaging are covered before legacy writers are removed.

### Read-only runtime integration

`PageModel`, `SyncController`, and `BackdropModel` construct from one resolved snapshot while preserving inert construction and delayed service startup.

### UI writer integration

UI edits and resets flow through the settings store, use the selected conflict policy, and preserve connection validation-before-persistence.

### Legacy writer removal

Migrated `defaults.set` calls are removed only after all readers and runtime consumers use the settings store. Retained defaults serve rollback only for the explicitly defined compatibility window.

### Documentation and end-to-end verification

The user-facing format reference documents paths, syntax, schema, fields, defaults, validation, reset behavior, external edits, recovery, and file-only settings. Packaging and integration checks verify the complete application artifact.

## Open questions

1. Does the format remain constrained JSON with comments and trailing commas, or become full JSON5?
2. Are backdrop geometry and pinning configuration or local window state?
3. Does `floatsOnTop` remain supported after the archived panel target?
4. Do external edits apply at restart, through explicit reload, or through file watching?
5. How does the canonical writer detect and handle stale external edits?
6. Are unknown fields ignored, preserved, or rejected?
7. What happens when the UI attempts to write while the existing user file is malformed?
8. What is the transaction outcome when a Keychain token update and non-secret connection-file update do not both succeed?
9. How long are legacy defaults retained for rollback?
10. Does assigning a value equal to the bundled default retain an explicit override, with reset remaining a separate removal operation?

## Rejected direction

A permanent `UserDefaults` store for UI edits with a JSON overlay is not recommended. It creates two persistent sources of truth, makes precedence visible to users only through surprising behavior, and leaves external file edits disconnected from UI ownership.
