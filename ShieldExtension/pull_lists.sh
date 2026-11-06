#!/bin/bash
# Copies roko's blocking from the iOS repository (where it's built) into lists/:
# what build.py turns into the extension. Takes the branch that ships, not
# whatever happens to be checked out there.
#   ShieldExtension/pull_lists.sh [path to the iOS repository] [ref]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${1:-$HOME/Documents/Browser}"
REF="${2:-origin/main}"
git -C "$REPO" fetch -q origin
mkdir -p "$HERE/lists"
for kind in ads privacy cookies popups; do
  for file in "$kind.json" "$kind-hosts.txt" "$kind-hide.txt"; do
    git -C "$REPO" show "$REF:Browser/Resources/Blocklists/$file" > "$HERE/lists/$file"
  done
done
git -C "$REPO" show "$REF:Browser/Resources/Blocklists/site-scripts.txt" > "$HERE/lists/site-scripts.txt"
git -C "$REPO" show "$REF:Browser/Resources/Blocklists/version.txt" > "$HERE/lists/version.txt"
for file in cosmetic-filter.js consent-main.js consent-frame.js consent-frame-gate.json site-scripts.js; do
  git -C "$REPO" show "$REF:Browser/Resources/Scripts/$file" > "$HERE/lists/$file"
done
echo "lists/ is now at $(git -C "$REPO" rev-parse --short "$REF") of the iOS repository, lists version $(cat "$HERE/lists/version.txt")"
