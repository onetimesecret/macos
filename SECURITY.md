# Security Policy

This project uses Onetime Secret's existing disclosure process — there is
no parallel channel. Email `security@onetimesecret.com` with the subject
line "Vulnerability Report: [Brief Description]", per the
[Onetime Secret security policy](https://github.com/onetimesecret/onetimesecret/blob/develop/SECURITY.md).

## Scope note

The memory-hygiene claims in `docs/spec/05-technical-direction.md` —
zeroization of cell buffers on expiry/discard, no plaintext residence
outside the core, pasteboard marking, capture exclusion — are explicitly
**in scope** for reports. If the code does not do what the spec claims,
that is a vulnerability, not a nitpick.

The threat model is also documented there, including what is out of
scope (compromised local user account, kernel-level attackers, SIP
disabled).
