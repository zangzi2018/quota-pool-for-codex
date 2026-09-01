#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
node --check relay/src/server.mjs
node --check relay/src/store.mjs
(cd relay && node --test test/*.test.mjs)
node -e "for (const f of ['shared/snapshot.schema.json','ios/CodexAccounts/Assets.xcassets/Contents.json','ios/CodexAccounts/Assets.xcassets/AccentColor.colorset/Contents.json','ios/CodexAccounts/Assets.xcassets/AppIcon.appiconset/Contents.json']) JSON.parse(require('fs').readFileSync(f));"
if command -v xcodegen >/dev/null 2>&1; then (cd ios && xcodegen generate); (cd companions/macos && xcodegen generate); fi
if command -v dotnet >/dev/null 2>&1; then dotnet build companions/windows/CodexAccounts.Companion.sln; fi
