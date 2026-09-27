#!/usr/bin/env bash
# Downloads the two dev tools the checks need. Both ship prebuilt Linux and
# Windows x86_64 binaries; nothing here is part of the shipped camera package.
#
#   luau          reference interpreter, runs the logic unit tests
#   luau-lsp      ships `luau-lsp analyze`, the strict type checker
#
# Set TOOLS_DIR to install somewhere else. Defaults to <repo>/.tools, which is
# gitignored; an existing <repo>/../.tools is reused so an established checkout
# keeps working.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${TOOLS_DIR:-}" ] && [ -x "$ROOT/../.tools/luau" ] && [ -x "$ROOT/../.tools/luau-lsp" ]; then
	DEST="$ROOT/../.tools"
else
	DEST="${TOOLS_DIR:-$ROOT/.tools}"
fi
mkdir -p "$DEST"
cd "$DEST"

echo "fetching luau and luau-lsp into $DEST"
curl -sSL -o luau.zip https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
curl -sSL -o luau-lsp.zip https://github.com/JohnnyMorganz/luau-lsp/releases/latest/download/luau-lsp-linux-x86_64.zip
unzip -oq luau.zip
unzip -oq luau-lsp.zip
rm -f luau.zip luau-lsp.zip
chmod +x luau luau-lsp luau-analyze 2>/dev/null || true

# On Windows the equivalent assets are luau-windows.zip and luau-lsp-win64.zip.

echo "installed:"
ls -1 luau luau-lsp
