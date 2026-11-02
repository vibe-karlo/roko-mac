#!/bin/bash
# Builds src/consent-snippets.js: Autoconsent's page-world steps (its
# lib/eval-snippets.ts, MPL-2.0), which the cookie script asks for by name and
# background.js runs in the page. Chrome won't run code handed over as text,
# so the steps travel inside the extension, as in Autoconsent's own extension.
# Run when roko's Autoconsent version changes (Scripts/build_consent.sh in the
# iOS repository). Needs node and npm.
set -euo pipefail
VERSION=16.60.0
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
npm init -y >/dev/null
npm install --silent --no-audit --no-fund "@duckduckgo/autoconsent@$VERSION" esbuild@0.25.10 >/dev/null
printf 'export { snippets } from "./node_modules/@duckduckgo/autoconsent/lib/eval-snippets.ts";\n' > entry.js
npx esbuild entry.js --bundle --format=esm --target=chrome120 --log-level=warning \
  --banner:js="// Built by ShieldExtension/build_snippets.sh from @duckduckgo/autoconsent $VERSION (MPL-2.0, https://github.com/duckduckgo/autoconsent)." \
  --outfile="$HERE/src/consent-snippets.js"
ls -l "$HERE/src/consent-snippets.js"
