---
# docs/development/build-records.md
---

# Build records

The [packaging script](../../scripts/package-app.sh) records the source of
each build it packages as a git ref. This guide reads a bundle's source stamp
and lists, inspects, checks out, pushes, and prunes those records.

## What a build records

| Lane | Entry point | Committed tree | Uncommitted changes |
| --- | --- | --- | --- |
| dev | `scripts/dev.sh`, which runs `package-app.sh --debug` | `refs/builds/dev/<version>-<commit>` | `refs/builds/dev/<version>-<commit>-<tree>` |
| local | `scripts/install.sh`, which runs `package-app.sh` | `refs/builds/local/<version>-<commit>` | `refs/builds/local/<version>-<commit>-<tree>` |
| app-store | `package-app.sh --app-store` | tags `build/app-store/<version>-<build number>` and `v<version>` | refused before compiling |

`<version>` is `CFBundleShortVersionString` from `shell/OnetimePad-Info.plist`.
`<commit>` is the first 12 hex characters of the source commit, and `<tree>`
the first 12 of the packaged tree.

Every record is an annotated tag object. Dev and local records are written with
`git mktag` and `git update-ref` under `refs/builds/`, outside `refs/tags/`, so
`git push --tags`, `git push --follow-tags` and `push.followTags` do not send
them; `git push --mirror` does. Only App Store tags are under `refs/tags/`.

### Reading the source

Before compiling, the script reads HEAD and the tree `git add -A` would
commit: tracked edits plus untracked files git does not ignore, staged in a
temporary copy of the index rather than the real one. The build is dirty when
that tree differs from HEAD's or cannot be read.

The build is also dirty when any index entry is flagged assume-unchanged or
skip-worktree (`git ls-files -v` shows a lowercase letter or `S`), because
`git add -A` does not see edits to those files. The script names up to five
of them, and the build gets no snapshot and no record. A sparse checkout flags
entries skip-worktree, so it gets no records.

After compiling, the script reads the tree again. If the tree changed or
cannot be read, including a file written during the build such as agent memory
under `.claude/agent-memory/`, the script warns, stamps the build dirty against
the HEAD it first read, and writes no record. `--app-store` exits there,
before reserving a build number. A HEAD that moved while the tree did not
voids nothing: if the new commit's tree is the one built, that commit becomes
the source; otherwise the HEAD read first stays the source.

`--app-store` refuses before compiling in CI, when there is no HEAD (outside a
git checkout, on an unborn branch, or with a missing object), when the tree
cannot be read, and when the build is dirty. It suggests committing the changes
or `git stash -u`, which also takes untracked files. With `--build-number N`,
it also refuses when the tag `build/app-store/<version>-N` already names
another commit.

### Writing the record

A build that finishes writes its record last:

- **Committed tree, dev or local.** An annotated tag object for the source
  commit at `refs/builds/<lane>/<version>-<commit>`.
- **Uncommitted changes, dev or local.** A snapshot commit of the tree, with
  the source commit as its parent, and an annotated tag object for it at
  `refs/builds/<lane>/<version>-<commit>-<tree>`.
- **App Store.** An annotated, unsigned `build/app-store/<version>-<build number>`
  tag, and `v<version>` when no tag of that name exists. The `v` tag follows
  `tag.gpgSign`. The script then prints a `git push` command.

The script pushes nothing. When `CI` is set to anything other than empty,
`false` or `0`, it writes no tag, snapshot, or record, and `--app-store`
refuses to run.

Each name is checked with `git check-ref-format` first. An invalid dev or local
name means no snapshot and no record. For `--app-store`, an invalid
`build/app-store` name stops the run before a build number is reserved. Right
after reserving a number, the script checks its `build/app-store` tag. If that
tag already names another commit, the run stops before stamping or signing, and
the number stays unused.

A record that already points at the same commit is reused and keeps its first
annotation; the script says so. One that points at another commit is left as
it is, with a warning, and the build gets no record under that name.

When git refuses a write, the script prints git's error and a shell quoted
command to run by hand:

- **Dev or local.** `git update-ref <ref> <commit>`, which keeps a plain
  record without the annotation. The build still succeeds. When the snapshot
  commit itself cannot be made, the build is stamped dirty with no record.
- **App Store.** The `git tag` command for the `build/app-store` tag. The
  script says the package was built with no record and exits 1, without
  tagging `v<version>` or printing a push command. It does the same, without
  the `git tag` command, when that tag already names another commit. A
  `v<version>` tag that is not written is a warning only, and the push command
  leaves it out.

### Annotation

The first line is `OnetimePad <version>, <lane> build <CFBundleVersion>`. The
fields that follow:

| Field | Value |
| --- | --- |
| `Version` | `CFBundleShortVersionString` |
| `Build` | `CFBundleVersion` |
| `Lane` | `dev`, `local`, or `app-store` |
| `Configuration` | `debug` or `release` |
| `Bundle identifier` | the lane's bundle id |
| `Source` | the full commit; for a snapshot, `<commit> with uncommitted changes in snapshot <snapshot>` |
| `Signing` | `ad-hoc`, or `team <Team ID>` |
| `Pre-signature digest` | the digest written to `dist/<bundle name>.presig.sha256` |
| `Core`, `FFI` | versions from `crates/core/Cargo.toml` and `crates/ffi/Cargo.toml` |
| `Swift`, `Rust`, `Xcode` | first line of `swift --version`, `rustc --version`, `xcodebuild -version`; `unknown` when empty or when the text has a slash |
| `Built` | UTC time, ISO 8601 |

No field names a path or a certificate subject. The tagger is your git
committer identity, name and email, and is public once a tag is pushed.

## Find the source of a bundle

```sh
APP="/Applications/OnetimePad Local.app"   # or "dist/OnetimePad Debug.app"
plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"
plutil -extract OnetimePadSourceRevision raw "$APP/Contents/Info.plist"
```

| Build | `CFBundleVersion` | `OnetimePadSourceRevision` |
| --- | --- | --- |
| Dev or local, committed tree | `<version>+<commit>` | full commit |
| Dev or local, snapshot recorded | `<version>+<commit>.dirty` | full snapshot commit |
| Dev or local, dirty with no snapshot | `<version>+<commit>.dirty` | `<full commit>.dirty` |
| Dev or local, no commit to read (outside a checkout, or no commits yet) | `<version>` | `unknown` |
| App Store | build number | full commit |

The diagnostics report shows the same two values. In
[DiagnosticsReport.swift](../../shell/Sources/OnetimePad/DiagnosticsReport.swift),
its first line is `OnetimePad <version> (<CFBundleVersion>)` and its second is
`Source: <OnetimePadSourceRevision>; lane: <lane>`. The **Help** menu's
**Copy Diagnostic Summary** and **Export Diagnostics…** both include them.

A committed dev or local build `<version>+<commit>` is recorded as
`refs/builds/<lane>/<version>-<commit>`. For a snapshot or an App Store build,
find the record that points at the revision:

```sh
git for-each-ref --points-at <snapshot> refs/builds
git tag --points-at <commit> -l 'build/*' 'v*'
```

## List records

```sh
git for-each-ref refs/builds    # dev and local
git tag -l 'build/*'            # App Store
```

## Inspect a record

A record is a full ref such as `refs/builds/local/<version>-<commit>`, the
shorter `builds/local/<version>-<commit>`, which git resolves through its
`refs/<name>` rule, or an App Store tag name such as
`build/app-store/<version>-<build number>`.

```sh
git show <record>
git cat-file -p <record>
```

`git show` prints the annotation, then the commit and its diff against its
parent. For a snapshot, that diff is the uncommitted work the build included.
`git cat-file -p` prints the tag object: the commit it names, the tagger, and
the annotation.

## Check out a record

```sh
git checkout <record>
```

This detaches HEAD at the recorded commit. A snapshot's checkout includes the
files that were untracked when it was built. Start from a clean tree.

## Push App Store tags

Run the command the script prints at the end of an App Store build:

```sh
git push origin build/app-store/<version>-<build number> v<version>
```

It names only the tags that point at the packaged commit; a `v<version>` tag
left on another commit is not in it. Dev and local records under
`refs/builds/` go only with `git push --mirror` or a refspec that names them.

## Prune local records

```sh
git update-ref -d refs/builds/<lane>/<version>-<commit>
git update-ref -d refs/builds/<lane>/<version>-<commit>-<tree>
```

Deleting a record leaves its objects in the repository until `git gc` prunes
unreachable objects older than `gc.pruneExpire`, two weeks by default. A
snapshot includes every untracked file git does not ignore, and every build
writes the contents of changed and untracked files into the object store as it
reads the tree, with or without a record.
