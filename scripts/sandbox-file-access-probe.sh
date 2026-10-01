#!/usr/bin/env bash
# sandbox-file-access-probe.sh
#
# Build scripts/sandbox-file-access-probe.swift into a small app bundle,
# sign it ad hoc with the entitlements under test, run its phases, and
# print the log. The evidence for ADR-0035; the source file's header
# says what each log line means.
#
#   bash scripts/sandbox-file-access-probe.sh [variant] [work-dir]
#
# Variants, which differ only in the entitlements the bundle is signed
# with:
#
#   rw           app-sandbox and files.user-selected.read-write. The
#                default, and the set scripts/Companion.entitlements
#                declares for file access.
#   none         app-sandbox alone.
#   rwbm         rw plus files.bookmarks.app-scope, the entitlement
#                ADR-0035 decides not to declare.
#   unsandboxed  no entitlements at all, for the claim that one code
#                path serves both lanes.
#
# work-dir is where the document, its ungranted neighbour and the log
# are made. It defaults to a fresh directory under /tmp, which a
# sandboxed process cannot read without a grant. Do not point it inside
# a sandbox container or at a directory the app may read anyway.
#
# The runs:
#
#   1. The app is handed doc.txt and log.txt. doc.txt arrives granted.
#   2. The app is handed log.txt alone: a relaunch with no grant.
#   3. doc.txt is moved to sub/renamed.txt and run 2 is repeated, which
#      shows whether each bookmark follows the file after a staged write
#      replaced it.
#
# The bundle lands in dist/sandbox-file-access-probe/, which git
# ignores. Each sandboxed variant leaves a container behind at
# ~/Library/Containers/dev.onetimesecret.sandboxprobe.<variant>; the
# stored bookmarks live there, and removing it is the way to start
# clean. The unsandboxed variant has no container and keeps its three
# files in
# ~/Library/Application Support/dev.onetimesecret.sandboxprobe.unsandboxed.
#
# swiftc is taken from the environment. If it stalls under a beta Xcode,
# export SDKROOT and DEVELOPER_DIR for that Xcode before running this.

set -euo pipefail

cd "$(dirname "$0")/.."

USAGE="usage: bash scripts/sandbox-file-access-probe.sh [rw | none | rwbm | unsandboxed] [work-dir]"
VARIANT="${1:-rw}"

SANDBOX_KEY="com.apple.security.app-sandbox"
RW_KEY="com.apple.security.files.user-selected.read-write"
BOOKMARK_KEY="com.apple.security.files.bookmarks.app-scope"

case "$VARIANT" in
  rw) KEYS="$SANDBOX_KEY $RW_KEY" ;;
  none) KEYS="$SANDBOX_KEY" ;;
  rwbm) KEYS="$SANDBOX_KEY $RW_KEY $BOOKMARK_KEY" ;;
  unsandboxed) KEYS="" ;;
  *)
    echo "$USAGE" >&2
    exit 2
    ;;
esac

# Absolute, because `open -a` takes a relative path for an application's
# name and looks it up, finding nothing.
OUT="$PWD/dist/sandbox-file-access-probe"
APP="$OUT/Probe-$VARIANT.app"
ENTITLEMENTS="$OUT/entitlements-$VARIANT.plist"

mkdir -p "$OUT"
# The deployment target is named, at the shell package's own floor
# (shell/Package.swift). Left to itself, swiftc under the beta Xcode on
# macOS 27.0 stamped the binary as needing macOS 28.0. A tool run from a
# shell starts anyway, but LaunchServices reads the stamp and refuses
# the bundle with error -10825, so nothing past the build would run.
TARGET="$(uname -m)-apple-macosx13.0"
echo "==> swiftc -target $TARGET scripts/sandbox-file-access-probe.swift"
swiftc -O -target "$TARGET" scripts/sandbox-file-access-probe.swift -o "$OUT/probe-bin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/probe-bin" "$APP/Contents/MacOS/Probe"

# The document type is what lets LaunchServices hand the app a file, and
# a file handed over that way is how the grant arrives without a panel.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.onetimesecret.sandboxprobe.$VARIANT</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundleName</key><string>Probe-$VARIANT</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Any</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSItemContentTypes</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST

{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  for key in $KEYS; do
    echo "<key>$key</key><true/>"
  done
  echo '</dict></plist>'
} > "$ENTITLEMENTS"

echo "==> codesign (ad hoc) $APP"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null || true
echo

if [[ $# -ge 2 ]]; then
  WORK="$2"
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d /tmp/sandbox-file-access-probe.XXXXXX)"
fi
printf 'line one\nline two\n' > "$WORK/doc.txt"
printf 'other\n' > "$WORK/other.txt"
: > "$WORK/log.txt"

# -W waits for the app, which exits by itself once it has written its
# lines. -n starts a new instance each time, so every run is a relaunch.
echo "==> run 1: doc.txt handed over with a grant"
open -W -n -a "$APP" "$WORK/doc.txt" "$WORK/log.txt"

echo "==> run 2: relaunch with no grant on doc.txt"
open -W -n -a "$APP" "$WORK/log.txt"

echo "==> run 3: doc.txt moved to sub/renamed.txt, relaunch again"
mkdir -p "$WORK/sub"
mv "$WORK/doc.txt" "$WORK/sub/renamed.txt"
open -W -n -a "$APP" "$WORK/log.txt"

echo "==> $WORK/log.txt"
cat "$WORK/log.txt"
