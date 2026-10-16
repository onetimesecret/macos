# Client and server contract inventory for the sync channel

**Status:** draft inventory, 2026-10-15. Not accepted. The server side
is not yet defined beyond this: the authorization server is
onetimesecret running rodauth-oauth, and the relay is a separate
service that does not exist yet (onetimesecret-internal#8, open). Every
row below therefore records what the built client sends and expects,
set beside what the one existing server artifact does today: the
`develop` branch of onetimesecret/onetimesecret at f7c8288bda
(2026-10-12), which carries the rodauth-oauth fork pinned at
`b0e7ceb0` (1.6.6.ots1). `main` does not carry it, and the staging
host onetimesecret.dev answered 404 on 2026-10-15 for
`/auth/.well-known/oauth-authorization-server`, `/auth/jwks` and
`/auth/authorize`, so no reachable OAuth server exists to test against
right now.

Column meanings: **Client** is what `crates/sync` and the shell do, by
code reading. **Server today** is `develop` as read, with the file and
line. **Standing** is one of: *match*, *gap* (the two disagree and one
side must move), *undefined* (no server behaviour exists yet), or
*expectation* (the client asserts something no server text supports).
Gaps name no winner; that is the owner's decision.

## 1. OAuth endpoints and client identity

| # | Item | Client | Server today | Standing |
| --- | --- | --- | --- | --- |
| 1.1 | Authorize path | `SyncEndpoints.resolve` defaults to `<server>/oauth/authorize` (`SyncController.swift:27`), overridable per UserDefaults key | `GET/POST /auth/authorize` (docs/authentication/oauth-server.md, Endpoints table; the mount prefix is `Auth::Application.uri_prefix`, features/oauth.rb:76) | gap: default path differs |
| 1.2 | Token path | default `<server>/oauth/token` (`SyncController.swift:28`) | `POST /auth/token` | gap: default path differs |
| 1.3 | Client id | default `onetime-companion` (`SyncController.swift:29`) | No such row. Only `onetimesecret-sp-dev` is seeded, dev and test only, with a client secret (initializers/seed_dev_oauth_client.rb). Registration is manual: "v1 does not ship a dynamic client registration endpoint — operators seed rows manually or via tooling." (oauth-server.md, Registering an OAuth Client) | undefined: a companion row must be provisioned |
| 1.4 | Discovery | Client reads no discovery document; endpoints are configured | `/auth/.well-known/oauth-authorization-server` and `openid-configuration` mounted in router.rb | match (unused by the client) |

## 2. Authorization request

| # | Item | Client | Server today | Standing |
| --- | --- | --- | --- | --- |
| 2.1 | Grant | `response_type=code` (`oauth.rs`, `AuthCeremony::begin`) | `oauth_response_types_supported %w[code]`; the override of `check_valid_response_type?` rejects everything else (features/oauth.rb:159-171) | match |
| 2.2 | PKCE | `code_challenge_method=S256`, 32 random octets, base64url (`AuthCeremony::begin`) | `oauth_require_pkce true`, `oauth_pkce_allow_plain_method false` (features/oauth.rb:121, 131) | match |
| 2.3 | Redirect URI | `http://127.0.0.1:{ephemeral}/callback`, exact path checked by the loopback listener | Fork normalizes a loopback IP by dropping the port before comparison (`normalize_redirect_uri_for_comparison`, oauth_authorize_base.rb:262-273 at b0e7ceb0), so a row registered as `http://127.0.0.1/callback` matches any port, as account-auth.md §1 requires | match, provided the row is registered portless |
| 2.4 | Redirect scheme | `http://` loopback | `oauth_valid_uri_schemes` defaults to `https` only in production; `OAUTH_VALID_URI_SCHEMES` overrides (features/oauth.rb:143). The scheme check is a regexp over the registered URI (`check_valid_uri?`, oauth_base.rb:918) with no loopback exemption | gap: a production-tagged server refuses the companion's redirect unless the env var admits `http`, or the server adds an RFC 8252 loopback exemption |
| 2.5 | Scope | `scope=sync`, exactly, and nothing else (`SYNC_SCOPE`, test `the_authorize_url_asks_for_exactly_the_sync_scope`) | Allow list `oauth_application_scopes %w[openid profile email offline_access]` (features/oauth.rb:110); a requested scope outside the application row's `scopes` column answers `invalid_scope` (oauth_authorize_base.rb:98, oauth_base.rb:912-916) | gap: no `sync` scope exists server side |
| 2.6 | Refresh token issuance | Client requires a refresh token in the code exchange answer: "a grant without a refresh token cannot serve an app that sleeps for days, so it is refused rather than half-kept" (`parse_token_response` doc comment) | With `:oidc` enabled, a refresh token is issued only when the granted scopes include `offline_access` (oidc.rb:769-772), and oidc.rb:319-324 drops `offline_access` unless `prompt=consent` accompanies it. oauth-server.md: "`offline_access` must survive the scope intersection. It has to be present in all three places: the client's `/authorize` request, the server allow-list (`oauth_application_scopes`), and the client's own `scopes` column" | gap: the client asks for neither `offline_access` nor `prompt=consent`, so today's server would issue no refresh token and the client would refuse the grant |
| 2.7 | `state` | 16 random octets; redirect without a matching `state` aborts (`redeem_refuses_a_wrong_or_missing_state`) | Server echoes `state` on success and on error redirects (oauth_base.rb:819-820) | match |
| 2.8 | Consent UI | Client opens the system browser and waits up to 5 minutes (account-auth.md §5) | `/authorize` is browser driven, CSRF kept (features/oauth.rb CSRF comment) | match; the consent page content is undefined |

## 3. Token exchange and refresh

| # | Item | Client | Server today | Standing |
| --- | --- | --- | --- | --- |
| 3.1 | Client authentication at `/token` | Public client: form body carries `client_id`, never a secret (`AuthCeremony::redeem`, `TokenKeeper::refresh_request`) | Server-wide list `oauth_token_endpoint_auth_methods_supported %w[client_secret_basic client_secret_post]` (features/oauth.rb:147). The fork's `require_oauth_application_from_none` accepts a secretless request only when the application row's own `token_endpoint_auth_method` column names `none` (oauth_base.rb:433-449) | gap: the companion row must carry `token_endpoint_auth_method = none`; the discovery document will still not advertise `none` |
| 3.2 | Code exchange body | `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier`, form encoded | rodauth-oauth authorization code grant with PKCE verifier check (oauth_pkce.rb:55-57) | match |
| 3.3 | Token answer fields | Reads `access_token` and `refresh_token` only; ignores `expires_in`, `token_type`, `id_token`, `scope` (`TokenBody`) | `json_access_token_payload` emits `access_token`, `token_type`, `expires_in`, and `refresh_token` when one exists (oauth_base.rb:681-687) | match |
| 3.4 | Refresh body | `grant_type=refresh_token`, `refresh_token`, `client_id`; no `scope` | `create_token` for `refresh_token` (oauth_base.rb:696-726) | match, subject to 3.1 |
| 3.5 | Rotation | Rotation requested, never required: an answer without a new refresh token keeps the resting one (ADR-0027 §2) | `oauth_refresh_token_protection_policy 'rotation'`: a new refresh token on every use (features/oauth.rb:100) | match |
| 3.6 | Reuse detection | Spec expects "server-side reuse detection" (account-auth.md §2) | Rotation policy looks the presented token up including revoked rows and answers `invalid_grant` when the row is revoked (oauth_base.rb:703-712). Whether reuse of a rotated token revokes the live grant is not established by this reading | expectation: verify against a running server |
| 3.7 | Refresh refused signal | Only a 4xx whose JSON body carries `"error":"invalid_grant"` signs sync out; any other failure is transient (`grant_is_dead`, test `only_invalid_grant_pronounces_the_grant_dead`) | `redirect_response_error("invalid_grant")` on an unknown or revoked token answers `400` JSON `{"error":"invalid_grant"}` when the request accepts JSON (oauth_base.rb:806-814, status 400 from `oauth_invalid_response_status`) | match, provided the client's token request is read as accepting JSON (`accepts_json?`): the client sends no `Accept` header, so this needs a real run |
| 3.8 | Access token lifetime | Never judged locally; the relay's `401` is the only expiry authority (account-auth.md §2) | 60 minutes (features/oauth.rb:93) | match |
| 3.9 | Refresh token lifetime | account-auth.md §2: "long idle allowance (90 days without use)" | 30 days, and measured from the last exchange, since every refresh rewrites `expires_in` (features/oauth.rb:94, oauth_base.rb:664) | gap: the spec text names 90 days; the server sets 30. account-auth.md §2 already says the lifetimes "are the server's to set", so this is a spec wording update unless the owner wants 90 |
| 3.10 | Access token format | Opaque to the client | RS256 JWT, keys from `OAUTH_JWT_RSA_PRIVATE_KEY`, public half at `/auth/jwks` (features/oauth.rb:307-308) | match; matters for the relay, see 4.1 |
| 3.11 | Revocation | Client never calls `/revoke`; sign-out deletes the Keychain entry | `POST /auth/revoke` mounted | match (unused) |

## 4. Relay

The relay is unbuilt. relay-protocol.md §4 is the client's wire
expectation, and internal#8 restates §9 as the build order. Nothing in
onetimesecret or onetimesecret-internal implements any `/channel/*`
route (grep on 2026-10-15). Every row is therefore *undefined* on the
server side; the column records what the client asserts.

| # | Item | Client expectation (code) | Standing |
| --- | --- | --- | --- |
| 4.1 | Attach auth | `Authorization: Bearer <access token>` on every request (`BearerAuth`, applied per request in `RelayApi::request`) | undefined: the relay must validate an OTS-issued RS256 JWT, which means fetching `/auth/jwks` and deciding the `aud` and `scope` claims it requires. Nothing names the audience today |
| 4.2 | Attach | `POST /channel/attach` `{device, key_package}`; answer must carry `epoch`, `frame_present`, `next_seq`, `peers[]` with `device`, `key_package`, `attached_ms`; a missing `peers` is a refusal (`an_attach_answer_without_a_roster_is_refused_not_guessed`) | undefined |
| 4.3 | Frame | `PUT /channel/frame` `{epoch, frame}` without `welcome` (client protocol §4.6); `GET /channel/frame` has no caller | undefined |
| 4.4 | Deltas | `POST /channel/deltas` `{epoch, blobs[]}` expecting `{seq}`; `GET /channel/deltas?since=&wait=` expecting `{epoch, blobs[], next_seq}` | undefined |
| 4.5 | Status map | `401` unauthorized, `409` epoch conflict, `410` rejoin, `413` ceremony required, anything else `Protocol(status)` (`the_protocol_statuses_map_to_their_moves`) | undefined |
| 4.6 | Pairing mailbox | `POST /channel/pairing` with an opaque JSON body; `GET /channel/pairing?since=` expecting `{messages[], next_seq}` | undefined |
| 4.7 | Detach | `POST /channel/detach`, answer ignored | undefined |
| 4.8 | Body limit | Transport refuses bodies over 10 MiB (`BODY_LIMIT`); client protocol §10.17 already notes an 8 MiB buffer in base64 exceeds it | gap inside the client's own documents |

## 5. Transport constraints a conformance suite must respect

- `UreqTransport` refuses any URL not starting with `https://`, follows no
  redirect, and when bounded refuses any host but the token endpoint's
  and the relay's (`crates/transport/src/lib.rs`). `SyncConfig::parse`
  refuses the three URLs unless `https://` (`sync_driver.rs:48-56`).
  A real-server suite therefore needs a TLS host, not `localhost:3000`.
  Weakening either check for tests is out of scope; a local run needs a
  TLS terminator in front of the dev server, or a staging host.
- The loopback listener binds `127.0.0.1` on an ephemeral port and
  serves one redirect (`loopback.rs`). A headless suite has to drive
  the browser step itself: sign in, submit consent, follow the
  redirect to the listener.

## 6. What must exist before one end-to-end case can pass

In dependency order:

1. A server with `AUTH_OAUTH_ENABLED=true` reachable over TLS, running
   code that carries rodauth-oauth. Today that is only `develop`.
2. A companion row in `oauth_applications`: portless loopback
   `redirect_uri`, `token_endpoint_auth_method` of `none`, grant types
   `authorization_code refresh_token`, and a `scopes` column the
   client's request can satisfy (2.5, 2.6, 3.1).
3. A decision on 2.5 and 2.6: either the server admits `sync` and
   issues refresh tokens for it outside the OIDC `offline_access` rule,
   or the client asks for `offline_access` with `prompt=consent`.
4. A decision on 2.4 for production-tagged deployments.
5. The shell's default paths (1.1, 1.2) aligned with the mount prefix,
   or the overrides documented as required.

Only after those does the thin case the proposal names (browser sign in,
code exchange, authenticated attach) have a server to run against, and
its last step still waits on the relay.
