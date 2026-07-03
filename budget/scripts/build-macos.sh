#!/usr/bin/env bash
#
# Build the macOS release app (with the local Google client id) and install it
# to /Applications, preserving existing app data.
#
# Usage:  budget/scripts/build-macos.sh
# Requires: FVM (project is pinned to Flutter 3.22.3) and budget/signin.json
#           (copy signin.json.example -> signin.json and fill in your client id).
#
# Your data lives in the sandbox container keyed by the bundle id
# (com.budget.budget); replacing the .app keeps that container, so updates
# apply while transactions/settings are preserved. Do NOT delete
# ~/Library/Containers/com.budget.budget unless you intend to wipe all data.

set -euo pipefail

# Move to the budget/ project root (this script lives in budget/scripts/).
cd "$(dirname "$0")/.."

KEY_FILE="signin.json"
APP_SRC="build/macos/Build/Products/Release/budget.app"
APP_DEST="/Applications/budget.app"

if ! command -v fvm >/dev/null 2>&1; then
  echo "error: fvm not found. Install it (brew install fvm) — the project needs Flutter 3.22.3." >&2
  exit 1
fi

if [ ! -f "$KEY_FILE" ]; then
  echo "error: $KEY_FILE not found." >&2
  echo "       cp signin.json.example signin.json  and fill in your client id." >&2
  exit 1
fi

echo "==> Building macOS release (fvm flutter build macos --release)…"
fvm flutter build macos --release --dart-define-from-file="$KEY_FILE"

if [ ! -d "$APP_SRC" ]; then
  echo "error: build did not produce $APP_SRC" >&2
  exit 1
fi

echo "==> Installing to $APP_DEST (existing data in the sandbox container is kept)…"
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

echo "==> Launching…"
open "$APP_DEST"
echo "Done. If macOS blocks it the first time: right-click the app -> Open."
