#!/usr/bin/env bash
#
# Build the VibeStarter Sync plugin and embed it into the Tauri app.
#
# This is the single, reproducible step for "ship a new plugin version":
#   1. builds the .rbxm from source with plugin.nospecs.project.json
#      (the shipped artifact — excludes *.spec test files), and
#   2. copies it over tauri-app/src-tauri/resources/VibeStarterSync.rbxm,
#      which the app embeds and installs into Studio (overwriting the old one).
#
# Run it whenever plugin/Version.txt or any plugin source changes, then commit
# the refreshed resources/VibeStarterSync.rbxm in tauri-app.
#
# Uses the FORK's release binary (target/release/rojo), not the rokit `rojo`
# on PATH (that one is upstream and a different version).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROJO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"            # vibestarter-sync/rojo
SYNC_DIR="$(cd "$ROJO_DIR/.." && pwd)"              # vibestarter-sync
PROJECTS_DIR="$(cd "$SYNC_DIR/.." && pwd)"          # projets
TAURI_RESOURCES="$PROJECTS_DIR/tauri-app/src-tauri/resources"

ROJO_BIN="$ROJO_DIR/target/release/rojo"
PROJECT_FILE="plugin.nospecs.project.json"
CANONICAL_OUT="$SYNC_DIR/build/VibeStarterSync.rbxm"
RESOURCE_OUT="$TAURI_RESOURCES/VibeStarterSync.rbxm"

VERSION="$(tr -d '[:space:]' < "$ROJO_DIR/plugin/Version.txt")"
echo "==> VibeStarter Sync plugin v$VERSION"

# Build the fork CLI once if its release binary is missing.
if [[ ! -x "$ROJO_BIN" ]]; then
	echo "==> Fork rojo binary missing — building it (cargo build --release)…"
	(cd "$ROJO_DIR" && cargo build --release)
fi

echo "==> Building plugin ($PROJECT_FILE)…"
mkdir -p "$(dirname "$CANONICAL_OUT")"
(cd "$ROJO_DIR" && "$ROJO_BIN" build "$PROJECT_FILE" --output "$CANONICAL_OUT")

if [[ ! -d "$TAURI_RESOURCES" ]]; then
	echo "ERROR: Tauri resources dir not found: $TAURI_RESOURCES" >&2
	echo "       The plugin was built to $CANONICAL_OUT but NOT embedded." >&2
	exit 1
fi

cp "$CANONICAL_OUT" "$RESOURCE_OUT"

echo "==> Embedded into the app:"
ls -la "$CANONICAL_OUT" "$RESOURCE_OUT"
echo
echo "Done. Now commit the updated resources/VibeStarterSync.rbxm in tauri-app to ship v$VERSION."
