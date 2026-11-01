#!/usr/bin/env bash
# Fail when a tracked text file contains an ideographic variation selector
# (U+E0100 to U+E01EF). Agent-written docs once carried one after nearly
# every character, invisible on screen but breaking search and diffs.
set -euo pipefail
cd "$(dirname "$0")/.."

if git ls-files -z -- '*.md' '*.swift' '*.rs' '*.toml' '*.json' '*.yml' \
    '*.yaml' '*.sh' '*.py' '*.plist' '*.strings' '*.txt' '*.html' '*.css' \
  | xargs -0 perl -ne '
      utf8::decode($_) or next;
      if (/[\x{E0100}-\x{E01EF}]/) { print "$ARGV:$.\n"; $found = 1 }
      close ARGV if eof;
      END { exit($found ? 1 : 0) }' > /tmp/invisible-characters.$$ 2>/dev/null; then
  rm -f /tmp/invisible-characters.$$
  echo "No invisible variation selectors in tracked text files."
else
  echo "Invisible variation selectors (U+E0100 to U+E01EF) found:" >&2
  sort -u /tmp/invisible-characters.$$ | head -50 >&2
  rm -f /tmp/invisible-characters.$$
  echo "Strip them with: git ls-files -z '*.md' | xargs -0 perl -CSD -i -pe 's/[\\x{E0100}-\\x{E01EF}]//g'" >&2
  exit 1
fi
