# 2026-09-30: sandbox file access probe, four variants

The output of
[`scripts/sandbox-file-access-probe.sh`](../../../../scripts/sandbox-file-access-probe.sh),
which builds and runs
[`scripts/sandbox-file-access-probe.swift`](../../../../scripts/sandbox-file-access-probe.swift),
on one Mac running macOS 27.0 (build 26A428) at 02:00 PDT on
2026-09-30. Each file opens with the date, the system version, the
compiler version and the command that produced it.

| File | Entitlements the probe app was signed with |
| --- | --- |
| `none.log` | `com.apple.security.app-sandbox` |
| `rw.log` | the sandbox and `com.apple.security.files.user-selected.read-write` |
| `rwbm.log` | those two and `com.apple.security.files.bookmarks.app-scope` |
| `unsandboxed.log` | none |

These are the runs the evidence table in
[ADR-0035](../../../adr/0035-sandboxed-file-access-holds-a-scope-around-core-io.md)
rests on, and the lines that record quotes are in them.

## What this is and is not

Tool output from one machine on one day. It shows what that system did
for an ad hoc signed probe handed files by LaunchServices under `/tmp`.
It is not a statement of what the platform documents, it did not run
OnetimePad, and it establishes no project claim by being here. The
ADR's Evidence section lists what these runs did not measure.

## The probe these runs came from

`SOURCES.sha256` holds the SHA-256 digests of the probe and its runner
as they were when the runs were made. From the repository root:

```sh
shasum -a 256 -c docs/qa/probe-runs/2026-0930-sandbox-file-access/SOURCES.sha256
```

A mismatch means the probe or the runner has been edited since, and a
new run would not be the same experiment.

## Notes on the copy

The runs were captured as `.txt` files. They are checked in as `.log`
because the repository's `.gitignore` ignores `*.txt` everywhere, and a
file that git ignores is left out of a commit without a word.

Earlier attempts from the same session, two that failed before the
probe launched and the runs made before the probe and its runner were
last changed, are not checked in.
