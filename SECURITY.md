# Security Policy

This project uses Onetime Secret's existing disclosure process — there is
no parallel channel. Email `security@onetimesecret.com` with the subject
line "Vulnerability Report: [Brief Description]", per the
[Onetime Secret security policy](https://github.com/onetimesecret/onetimesecret/blob/develop/SECURITY.md).

## Scope note

The memory-hygiene claims in `docs/spec/design/2026-0707-technical-direction.md` —
zeroization of cell buffers on expiry/discard, no plaintext residence
outside the core, pasteboard marking, capture exclusion — are explicitly
**in scope** for reports. If the code does not do what the spec claims,
that is a vulnerability, not a nitpick.

The threat model is also documented there, including what is out of
scope (compromised local user account, kernel-level attackers, SIP
disabled).

## Verifying a build

The packaging script hashes the app bundle it has just assembled,
before `codesign` runs, and writes the result beside it:
`dist/OnetimePad Local.presig.sha256` for the default local build,
`dist/OnetimePad.presig.sha256` for an App Store build.

The file holds one line, `<sha256>  <bundle name>.app`. The digest is
taken over every regular file in the bundle, by relative path and
content: `find` the bundle, sort the paths under `LC_ALL=C` so the
order is byte order rather than the caller's locale, hash each file,
then hash that listing. Relative paths so the digest does not depend on
where the checkout lives.

To reproduce it:

```sh
git checkout <tag>             # clean tree, see the note below
scripts/build-core.sh
scripts/package-app.sh
cat "dist/OnetimePad Local.presig.sha256"
```

In the public repository, each tag
`build/app-store/<version>-<build number>` names the commit an App Store
build came from, and `v<version>` names the commit of the released
build. Dev and local builds are recorded under `refs/builds/`, which
`git push --tags` does not send
([build records](docs/development/build-records.md)).

No digest is published for this lane, so compare that line with one
from another clean build of the same commit. Each `build/app-store`
tag's annotation names the pre-signature digest of the first build
packaged under that number, which differs from this recipe's, as below.
The build script stamps
`CFBundleVersion` with the first 12 characters of the commit, plus a
`.dirty` marker for an uncommitted tree, and `Info.plist` is inside the
digest, so an uncommitted change to any file git does not ignore changes
the hash even when it changes no compiled byte. Build from a clean
checkout of the same commit or the comparison is meaningless.

This recipe builds the local lane. An App Store build of the same commit
writes a different bundle identifier, `CFBundleVersion` and
`OnetimePadBuildLane` into `Info.plist`, so its digest differs, and
`--app-store` refuses to start without App Store signing identities and
a provisioning profile.

### What this covers

The unsigned payload, and nothing else.

It attests nothing about erasure at runtime. Zeroization of buffers,
pasteboard hygiene, the lifetime of staged content: none of that is
observable in a hash of the shipped files. Those claims are the ones
the scope note above puts in scope for reports, and they are checked by
reading the code and the tests, not by comparing a digest.

It also does not verify a downloaded `.app`. Signing embeds the
signature inside the Mach-O and stapling adds a notarization ticket
after the fact, so a shipped bundle is not bit-identical to the bytes
that were hashed, and there is no reversible path back to them. Check a
download with `codesign --verify --deep --strict -vvv` and
`spctl -a -vv`, which tell you it is what the publisher signed. That is
a different question from whether the source produces it, and the two
checks do not substitute for each other.

Finally, bit-identical output across two different machines is not
something this project verifies today. `rust-toolchain.toml` pins the
Rust compiler, but the Swift toolchain and the macOS SDK come from
whatever Xcode you have, the build sets no `SOURCE_DATE_EPOCH`, and
nothing remaps build paths out of the compiled artifacts. So a digest
mismatch between your machine and ours is a reason to investigate, not
proof of tampering. Report one if you see it; narrowing that gap is
work we want to do.
