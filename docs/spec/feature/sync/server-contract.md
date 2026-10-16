# Client and server contract inventory for the sync channel

**Status:** draft inventory, 2026-10-15, revised 2026-10-16. Not
accepted. The server side is not yet defined beyond this: the
authorization server is onetimesecret running rodauth-oauth, and the
relay is a separate service that does not exist yet
(onetimesecret-internal#8, open). Every row below therefore records
what the built client sends and expects, set beside what the one
existing server artifact does today: the `develop` branch of
onetimesecret/onetimesecret at f7c8288bda (2026-10-12), which carries
the rodauth-oauth fork pinned at `b0e7ceb0` (1.6.6.ots1). `main` does
not carry it, and the staging host onetimesecret.dev answered 404 on
2026-10-15 for `/auth/.well-known/oauth-authorization-server`,
`/auth/jwks` and `/auth/authorize`, so no reachable OAuth server exists
to test against right now.

[ADR-0027](../../../adr/0027-account-auth-gates-the-sync-channel.md)'s
decision history records: "Accepted after testing the portless loopback
registration, refresh behavior, and scope behavior against a running
`rodauth-oauth` server." Neither the ADR nor the
[decision background](account-auth-decision-background.md) names that
server or its configuration, so this inventory cannot rerun the test.
Its recorded answers agree with the mechanics read here (2.3, 2.9,
3.6), but two differ from the pinned server. The decision background
§2 says the refresh window "was verified valid at 359 days of idleness
and expired at 361". That matches the gem default
`oauth_refresh_token_expires_in` of 360 days (oauth_base.rb:33), not
the 30 days develop has carried since 2026-06-25 (#3239, 3.9). Its
Consequences say "The consent form answers `500` when nothing is
ticked", where the pin answers `invalid_scope` through a guard the fork
added on 2026-09-01 (3325dca; `check_valid_scopes?`,
oauth_authorize_base.rb:124-127). The interpretation here is that the
test ran a rodauth-oauth with default settings, before that guard,
rather than develop as configured. If so, it did not exercise develop's
`:oidc` refresh rule (2.6), its CSRF layer (2.8), or the companion row
develop lacks (1.3, 2.5), and the two records describe different
servers rather than one going stale.

Column meanings: **Client** is what `crates/sync` and the shell do, by
code reading. **Server today** is `develop` as read, with the symbol,
file and line. **Standing** is one of: *match*, *gap* (the two disagree
and one side must move), *undefined* (no server behaviour exists yet),
or *expectation* (the client asserts something no server text
supports). No row names which side moves unless an accepted record
already does (2.5); otherwise that is the owner's decision.

The server column is a reading at f7c8288bda and `b0e7ceb0`, not run,
and no check in this repository notices when either moves. After any
bump of either pin, re-read the column rather than trust it; the symbol
beside each line is there to find a moved line again. Server file names
are short: `features/oauth.rb` and `hooks/oauth.rb` are under
`apps/web/auth/config/` on develop, and `router.rb`, `initializers/`
and `docs/` are under `apps/web/auth/`; `oauth-server.md` is develop's
`docs/authentication/oauth-server.md`. `oauth_*.rb` and `oidc.rb` are
under `lib/rodauth/features/` in the fork, and `authorize.str` under
`templates/`.

## 1. OAuth endpoints and client identity

| # | Item | Client | Server today | Standing |
| --- | --- | --- | --- | --- |
| 1.1 | Authorize path | `SyncEndpoints.resolve` defaults to `<server>/oauth/authorize` (`SyncController.swift:27`), overridable per UserDefaults key | `GET/POST /auth/authorize` (oauth-server.md, Endpoints table); the mount prefix is `oauth_mount_prefix { Auth::Application.uri_prefix }` (features/oauth.rb:76) | gap: default path differs |
| 1.2 | Token path | default `<server>/oauth/token` (`SyncController.swift:28`) | `POST /auth/token` (same table and prefix) | gap: default path differs |
| 1.3 | Client id | default `onetime-companion` (`SyncController.swift:29`). The Rust tests in `crates/sync/src/oauth.rs` use `companion-macos`, a fixture that reaches no server; the id to provision is `onetime-companion` | No such row. Only `DEV_CLIENT_ID = 'onetimesecret-sp-dev'` is seeded (initializers/seed_dev_oauth_client.rb:32), only when `Onetime.development? \|\| Onetime.testing?` (:62), with a client secret and `client_secret_basic` (:110, :114). Registration is manual: "v1 does not ship a dynamic client registration endpoint — operators seed rows manually or via tooling." (oauth-server.md, Registering an OAuth Client) | undefined: a `onetime-companion` row must be provisioned (6.2) |
| 1.4 | Discovery | Client reads no discovery document; endpoints are configured | `/auth/.well-known/oauth-authorization-server` and `openid-configuration`, mounted by `load_oauth_server_metadata_route` and `load_openid_configuration_route` when `:oidc` is enabled (router.rb:355-361) | match (unused by the client) |

## 2. Authorization request

| # | Item | Client | Server today | Standing |
| --- | --- | --- | --- | --- |
| 2.1 | Grant | `response_type=code` (`AuthCeremony::begin`, `crates/sync/src/oauth.rs`) | `oauth_response_types_supported %w[code]` (features/oauth.rb:159); the `check_valid_response_type?` override rejects everything else (features/oauth.rb:167-171) | match |
| 2.2 | PKCE | `code_challenge_method=S256`, 32 random octets, base64url (`AuthCeremony::begin`) | `oauth_require_pkce true` (features/oauth.rb:121), `oauth_pkce_allow_plain_method false` (features/oauth.rb:131) | match |
| 2.3 | Redirect URI | `http://127.0.0.1:{ephemeral}/callback`, exact path checked by the loopback listener | `validate_authorize_params` compares the request's redirect against the row's `redirect_uri` list (oauth_authorize_base.rb:100-109) after `normalize_redirect_uri_for_comparison` drops a loopback IP's port (oauth_authorize_base.rb:262-273), so a row registered as `http://127.0.0.1/callback` matches any port, as [account-auth.md](account-auth.md) §1 requires | match, provided the row is registered portless |
| 2.4 | Redirect scheme | `http://` loopback | `oauth_valid_uri_schemes` is `https` only when `Onetime.production?`, and `OAUTH_VALID_URI_SCHEMES` overrides it (features/oauth.rb:142-143). Its one reader, `check_valid_uri?` (oauth_base.rb:918-920), runs only in features develop does not enable (`auth.enable`, features/oauth.rb:44-47): application management, dynamic client registration, signed authorization requests, resource indicators and RP initiated logout. `/authorize` checks the redirect against the row alone (2.3). oauth-server.md (URI Scheme Restriction) says the opposite: "which is why production refuses it by default" | match by code reading: a seeded loopback row passes in a production-tagged deployment. develop's own doc says it is refused, so a run settles it (6.5). Tracked as onetimesecret/onetimesecret-internal#32 |
| 2.5 | Scope | `scope=sync`, exactly, and nothing else (`SYNC_SCOPE`, test `the_authorize_url_asks_for_exactly_the_sync_scope`) | `validate_authorize_params` answers `invalid_scope` for a requested scope outside the row's `scopes` column (oauth_authorize_base.rb:117; `check_valid_scopes?`, oauth_base.rb:912-916). The server allow list `oauth_application_scopes %w[openid profile email offline_access]` (features/oauth.rb:110) is not on that path at this pin: it feeds discovery's `scopes_supported` (`oauth_server_metadata_body`, oauth_base.rb:808) and row creation features develop does not enable | undefined: a row whose `scopes` column holds `sync` admits the request, and `sync` is missing only from discovery. ADR-0027's Consequences already decide the server side: "Server registration must remain portless and limited to the `sync` scope; those are operational requirements, not optional client preferences." |
| 2.6 | Refresh token issuance | Client requires a refresh token in the code exchange answer: "a grant without a refresh token cannot serve an app that sleeps for days, so it is refused rather than half-kept" (`parse_token_response` doc comment) | Under `:oidc`, `generate_token` issues a refresh token only when the grant's scopes include `offline_access` (oidc.rb:779-783), and `validate_authorize_params` drops `offline_access` unless `prompt=consent` and a `code` response type accompany it (oidc.rb:326-337). The fork's `check_valid_scopes?` exempts `offline_access` from the row check (oauth_authorize_base.rb:124-130), and the consent form carries it as a hidden field (authorize.str:64-65) beside `prompt` (`authorize_form_params`, oidc.rb:238-246). oauth-server.md: "`offline_access` must survive the scope intersection. It has to be present in **all three** places: the client's `/authorize` request, the server allow-list (`oauth_application_scopes`), and the client's own `scopes` column"; at this pin only the request and `prompt=consent` are read | gap: the client asks for neither `offline_access` nor `prompt=consent`, so today's server would issue no refresh token and the client would refuse the grant. oauth-server.md's three-places rule is tracked as onetimesecret/onetimesecret-internal#33 |
| 2.7 | `state` | 16 random octets; redirect without a matching `state` aborts (`redeem_refuses_a_wrong_or_missing_state`) | Echoed on success (`do_authorize`, oauth_authorization_code_grant.rb:64) and on error redirects (`redirect_response_error`, oauth_base.rb:833-834) | match |
| 2.8 | Consent UI | Client opens the system browser and waits up to 5 minutes ([account-auth.md](account-auth.md) §5) | develop has no authorize template of its own ("No app-level authorize view overrides the gem template", docs/review-oauth-omniauth-dual-role-3104.md:77), so the page is the fork's `authorize.str`: one unticked checkbox per offered scope (authorize.str:63-75, and 2.9). A POST with no box ticked answers `invalid_scope` (`check_valid_scopes?`, oauth_authorize_base.rb:124-127), unless the request carried `offline_access`, whose hidden field is then granted alone (2.6). The form carries only rodauth's `csrf_tag` (authorize.str:2), checked by `check_csrf?` (oauth_authorize_base.rb:62-69). develop's Rack layer, `InstrumentedAuthenticityToken` with `authenticity_param: 'shrimp'`, also covers `/auth`, and its `allow_if` leaves `/auth/authorize` out on purpose: "NOT bypassed: /authorize." (lib/onetime/middleware/registry.rb:111-114, 173). develop's review note records the result as a HIGH defect: "The browser consent step cannot complete" (docs/review-oauth-omniauth-dual-role-3104.md:67-89) | gap: by code reading the consent POST is refused before rodauth runs, so no browser sign in completes on develop today (6.3). Once it does, sign in succeeds only if the user ticks `sync`. Not run. Tracked as onetimesecret/onetimesecret-internal#31 |
| 2.9 | Consent scope set | The `SYNC_SCOPE` doc comment (`crates/sync/src/oauth.rs:22-27`) names ADR-0027's Consequences as what bounds a leaked token and says nothing about how the consent page picks scopes. An earlier version said that "a consent screen offers the application's registered scopes rather than the requested ones"; the fork reading below retired it | The page offers `authorize_scopes`: the request's `scope` when present, the row's `scopes` column only when the request omits it (oauth_authorize_base.rb:71-75). The request's `scope` is not carried into the POST (`authorize_form_params`, oauth_authorize_base.rb:83-93). The POST grants the `scope[]` values it submits, checked against the row's `scopes` column with `offline_access` exempt (`check_valid_scopes?`, oauth_authorize_base.rb:124-130), and stores them (`create_oauth_grant`, oauth_authorize_base.rb:211-215) | undefined: the row waits on 1.3 and 2.5. The [decision background](account-auth-decision-background.md) §3's consent sentence is true only for a request without `scope`. The ceiling stands apart from `offline_access`, which the fork exempts (2.6): the row's `scopes` column bounds every other scope granted under this client id, whatever the request asked. The companion's own grant is what the user ticks from `scope=sync`, but a row that also held `openid profile email` would let another local process, starting its own request under the public `onetime-companion` id, obtain them. 2.6 does not need `offline_access` on the row at this pin, so the row holds `sync` and nothing else (6.2) |

## 3. Token exchange and refresh

| # | Item | Client | Server today | Standing |
| --- | --- | --- | --- | --- |
| 3.1 | Client authentication at `/token` | Public client: form body carries `client_id`, never a secret (`AuthCeremony::redeem`, `TokenKeeper::refresh_request`) | Server-wide list `oauth_token_endpoint_auth_methods_supported %w[client_secret_basic client_secret_post]` (features/oauth.rb:147), which feeds discovery (`oauth_server_metadata_body`, oauth_base.rb:812). `require_oauth_application_from_none` accepts a secretless request only when `supports_auth_method?` finds `none` in the row's own `token_endpoint_auth_method` column (oauth_base.rb:447-463) | gap: the companion row must carry `token_endpoint_auth_method = none`; the discovery document will still not advertise `none` |
| 3.2 | Code exchange body | `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier`, form encoded | `create_token` for `authorization_code` (oauth_authorization_code_grant.rb:141-151), with the PKCE verifier check in `create_token_from_authorization_code` (oauth_pkce.rb:61-67) and `check_valid_grant_challenge?` (oauth_pkce.rb:93) | match |
| 3.3 | Token answer fields | Reads `access_token` and `refresh_token` only; ignores `expires_in`, `token_type`, `id_token`, `scope` (`TokenBody`) | `json_access_token_payload` emits `access_token`, `token_type`, `expires_in`, and `refresh_token` when one exists (oauth_base.rb:695-703); the `:oidc` override adds `id_token` when the grant has one (oidc.rb:697-701) | match |
| 3.4 | Refresh body | `grant_type=refresh_token`, `refresh_token`, `client_id`; no `scope` | `create_token` for `refresh_token` (oauth_base.rb:715-744) | match, subject to 3.1 |
| 3.5 | Rotation | Rotation requested, never required: an answer without a new refresh token keeps the resting one ([decision background](account-auth-decision-background.md) §2) | `oauth_refresh_token_protection_policy 'rotation'` (features/oauth.rb:100): `create_token` mints a new refresh token on every use (oauth_base.rb:727-737) | match |
| 3.6 | Reuse detection | [account-auth.md](account-auth.md) §2: "rotated on every use with server-side reuse detection" | Rotation writes the new refresh token over the row's (`_generate_refresh_token`, oauth_base.rb:557-567, written by `create_token_from_token`, oauth_base.rb:746-757), so a replayed token matches no row and `create_token` answers `invalid_grant` (oauth_base.rb:720, 725-726) exactly as for an unknown token. The live grant stays standing. The [decision background](account-auth-decision-background.md) §2 records the same of the tested server: "reuse detection does not revoke the family." | expectation: the server refuses a replay and revokes nothing. The client already assumes no family revocation (decision background §2); only account-auth.md §2's wording claims more |
| 3.7 | Refresh refused signal | Only a 4xx whose JSON body carries `"error":"invalid_grant"` signs sync out; any other failure is transient (`grant_is_dead`, test `only_invalid_grant_pronounces_the_grant_dead`) | `redirect_response_error("invalid_grant")` throws a `400` JSON body carrying `"error":"invalid_grant"` when `accepts_json?` (oauth_base.rb:820-828; status `oauth_invalid_response_status`, oauth_base.rb:90). `accepts_json?` is true for any request to `token_path` whatever its `Accept` (oauth_base.rb:198-204), and `token_path` is `/auth/token`, since the fork's `*_path` helpers prepend `oauth_mount_prefix` (lib/rodauth/oauth.rb:23-25; features/oauth.rb:76) | match; the client's missing `Accept` header does not matter at `/token` |
| 3.8 | Access token lifetime | Never judged locally; the relay's `401` is the only expiry authority ([account-auth.md](account-auth.md) §2) | `oauth_access_token_expires_in 3600`, 60 minutes (features/oauth.rb:93) | match |
| 3.9 | Refresh token lifetime | [account-auth.md](account-auth.md) §2: "long idle allowance (90 days without use)" | `oauth_refresh_token_expires_in`, 30 days (features/oauth.rb:94), measured from the last exchange: `oauth_grant_by_refresh_token_ds` keeps a token while `expires_in + refresh_ttl - access_ttl` is ahead (oauth_base.rb:677-678), and `create_token` rewrites `expires_in` on every refresh (oauth_base.rb:722-723) | gap: the spec text names 90 days; the server sets 30. account-auth.md says "the token lifetimes in §2 are the server's to set" (account-auth.md:27, preamble), so this is a spec wording update unless the owner wants 90. The decision background §2's "an app asleep for months wakes signed in" holds at the tested 360 days, not at 30 |
| 3.10 | Access token format | Opaque to the client | RS256 JWT: `oauth_jwt_keys` from `OAUTH_JWT_RSA_PRIVATE_KEY`, public half via `oauth_jwt_public_keys` at `/auth/jwks` (features/oauth.rb:307-308) | match; matters for the relay, see 4.1 |
| 3.11 | Revocation | Client never calls `/revoke`; sign-out deletes the Keychain entry | `POST /auth/revoke`, mounted by `:oauth_token_revocation` (`auth.enable`, features/oauth.rb:47) | match (unused) |

## 4. Relay

The relay is unbuilt. [relay-protocol.md](relay-protocol.md) §4 is the
client's wire expectation, and internal#8 restates §9 as the build
order. Nothing in onetimesecret or onetimesecret-internal implements
any `/channel/*` route (grep on 2026-10-15). Every row is therefore
*undefined* on the server side; the column records what the client
asserts.

| # | Item | Client expectation (code) | Standing |
| --- | --- | --- | --- |
| 4.1 | Attach auth | `Authorization: Bearer <access token>` on every request (`BearerAuth`, applied per request in `RelayApi::request`) | undefined: the relay must validate an OTS-issued RS256 JWT, which means fetching `/auth/jwks` and deciding the `aud` and `scope` claims it requires. Nothing names the audience today |
| 4.2 | Attach | `POST /channel/attach` `{device, key_package}`; answer must carry `epoch`, `frame_present`, `next_seq`, `peers[]` with `device`, `key_package`, `attached_ms`; a missing `peers` is a refusal (`an_attach_answer_without_a_roster_is_refused_not_guessed`) | undefined |
| 4.3 | Frame | `PUT /channel/frame` `{epoch, frame}` without `welcome` ([client-protocol.md](client-protocol.md) §4.6); any `2xx` is success where relay-protocol.md §4 names `204` (`parse_publish_frame`, `crates/sync/src/relay.rs:257-262`). `GET /channel/frame` has no caller (client-protocol.md:180), but its parser reads `404` as an absent frame, not a refusal (`parse_frame`, `relay.rs:222-225`) | undefined |
| 4.4 | Deltas | `POST /channel/deltas` `{epoch, blobs[]}` expecting `{seq}`; `GET /channel/deltas?since=&wait=` expecting `{epoch, blobs[], next_seq}` | undefined |
| 4.5 | Status map | `401` unauthorized, `409` epoch conflict, `410` rejoin, `413` ceremony required, anything else `Protocol(status)`, by status alone with the body unread (`refusal`, `relay.rs:361-369`; `the_protocol_statuses_map_to_their_moves`) | undefined |
| 4.6 | Pairing mailbox | `POST /channel/pairing` with an opaque JSON body; `GET /channel/pairing?since=` expecting `{messages[], next_seq}` | undefined |
| 4.7 | Detach | `POST /channel/detach`, answer ignored | undefined |
| 4.8 | Body limit | `BODY_LIMIT` bounds the response body only, at 10 MiB (`crates/transport/src/lib.rs:131`), as [client-protocol.md](client-protocol.md):100 scopes it ("response body 10 MiB"); the request body goes out unmeasured (`lib.rs:119-122`). Client protocol §10.17 notes the base64 of an 8 MiB buffer exceeds the response limit | gap inside the client's own documents, and on the wire: an oversized `POST /channel/deltas` is not refused locally, so it reaches the relay or a proxy in front of it, and a `413` from either is taken as ceremony required (4.5), because the client never reads relay-protocol.md §4's `ceremony_required` body |

## 5. Transport constraints a conformance suite must respect

- `UreqTransport` refuses any URL not starting with `https://`
  (`https_only(true)`), follows no redirect (`max_redirects(0)`), and
  when `bounded` refuses any host but the token endpoint's and the
  relay's (`crates/transport/src/lib.rs:56-57, 75`).
  `SyncConfig::parse` refuses the three URLs unless `https://`
  (`sync_driver.rs:50-61`). A real-server suite therefore needs a TLS
  host, not `localhost:3000`. Weakening either check for tests is out
  of scope; a local run needs a TLS terminator in front of the dev
  server, or a staging host.
- The loopback listener binds `127.0.0.1` on an ephemeral port and
  serves one redirect (`loopback.rs`). A headless suite has to drive
  the browser step itself: sign in, tick `sync` and submit consent,
  which develop refuses today (2.8), then follow the redirect to the
  listener.

## 6. What must exist before one end-to-end case can pass

In dependency order:

1. A server with `AUTH_OAUTH_ENABLED=true` reachable over TLS, running
   code that carries rodauth-oauth. Today that is only `develop`.
2. A `onetime-companion` row in `oauth_applications` (1.3): portless
   loopback `redirect_uri`, `token_endpoint_auth_method` of `none`,
   grant types `authorization_code refresh_token`, and a `scopes`
   column holding `sync` and nothing else (2.5, 2.9, 3.1). At this pin
   the row needs no `offline_access` whichever way 2.6 goes.
3. A consent POST develop accepts (2.8): either the authorize form
   also carries `shrimp`, or the Rack layer admits `/auth/authorize`
   and leaves it to rodauth's own check, as develop's review note
   proposes.
4. A decision on 2.6. ADR-0027's Consequences settle 2.5 (the row
   above). The server route, issuing refresh tokens for `sync` outside
   the OIDC `offline_access` rule, stays inside the accepted record.
   The client route, asking for `offline_access` with `prompt=consent`,
   leaves the row at `sync` but changes the request ADR-0027's Decision
   fixes: "request the single `sync` scope explicitly"
   (ADR-0027:36-37; the [decision background](account-auth-decision-background.md)
   §3 says the same). Taking it reopens that Decision.
5. A run that settles 2.4: by code reading a seeded loopback row passes
   in a production-tagged deployment, and develop's own doc says it is
   refused.
6. The shell's default paths (1.1, 1.2) aligned with the mount prefix,
   or the overrides documented as required.

Only after those does the thin case the proposal names (browser sign in,
code exchange, authenticated attach) have a server to run against, and
its last step still waits on the relay.
