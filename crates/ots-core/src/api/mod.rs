//! The Onetime Secret v3 API client.
//!
//! Milestone-1 scope is a single call: promote a text cell to a one-time link
//! via `POST /api/v3/secret/conceal` (docs/00 §12). Authentication is HTTP
//! Basic — the customer's external id (`extid`) as the username, an API token
//! as the password — with the seam shaped so swapping Basic for PASETO later is
//! a contained change.
//!
//! The request-body, auth-header, and response-parsing logic are always
//! compiled and unit-tested; only the network send sits behind the `http`
//! feature so the pure logic stays portable and fast to build.

mod conceal;

pub use conceal::{
    auth_header, build_body, parse_response, ConcealClient, ConcealError, ConcealOpts, Credentials,
    ShareLink,
};
