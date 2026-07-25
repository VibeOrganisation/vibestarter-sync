#!/usr/bin/env bash
#
# Build the VibeStarter Sync plugin and embed it into the Tauri app.
#
# This is the single, reproducible step for "ship a new plugin version":
#   1. builds the .rbxm from source with plugin.nospecs.project.json
#      (the shipped artifact — excludes *.spec test files), and
#   2. copies it to src-tauri/resources/VibeStarterSync.rbxm in the app repo,
#      which embeds and installs it into Studio (overwriting the old one).
#
# Run it whenever plugin/Version.txt or any plugin source changes, then commit
# the refreshed resources/VibeStarterSync.rbxm in the VibeStarter app repo.
#
# Uses the FORK's release binary (target/release/rojo), not the rokit `rojo`
# on PATH (that one is upstream and a different version).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROJO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"            # vibestarter-sync/rojo
SYNC_DIR="$(cd "$ROJO_DIR/.." && pwd)"              # vibestarter-sync
PROJECTS_DIR="$(cd "$SYNC_DIR/.." && pwd)"          # projets

ROJO_BIN="$ROJO_DIR/target/release/rojo"
PROJECT_FILE="plugin.nospecs.project.json"
PLUGIN_ARTIFACT="VibeStarterSync.rbxm"
CANONICAL_OUT="$SYNC_DIR/build/$PLUGIN_ARTIFACT"

# Set VIBESTARTER_APP_DIR to the app repository root when it is not in one of
# the usual locations. Otherwise, also detect a renamed sibling checkout by
# looking for the already-embedded plugin artifact.
resolve_tauri_resources() {
	local candidate
	local -a candidates
	local -a discovered=()

	if [[ -n "${VIBESTARTER_APP_DIR:-}" ]]; then
		candidates=("$VIBESTARTER_APP_DIR/src-tauri/resources")
	else
		candidates=(
			"$PROJECTS_DIR/vibestarter/src-tauri/resources"
			"$SYNC_DIR/vibestarter/src-tauri/resources"
		)
	fi

	for candidate in "${candidates[@]}"; do
		if [[ -d "$candidate" ]]; then
			(cd "$candidate" && pwd -P)
			return 0
		fi
	done

	if [[ -z "${VIBESTARTER_APP_DIR:-}" ]]; then
		for candidate in "$PROJECTS_DIR"/*/src-tauri/resources; do
			if [[ -f "$candidate/$PLUGIN_ARTIFACT" ]]; then
				discovered+=("$candidate")
			fi
		done

		if (( ${#discovered[@]} == 1 )); then
			(cd "${discovered[0]}" && pwd -P)
			return 0
		fi

		if (( ${#discovered[@]} > 1 )); then
			echo "ERROR: Multiple VibeStarter Tauri resources directories were found:" >&2
			printf '       - %s\n' "${discovered[@]}" >&2
			echo "       Set VIBESTARTER_APP_DIR to select the app repository." >&2
			return 1
		fi
	fi

	echo "ERROR: VibeStarter Tauri resources directory not found." >&2
	echo "       Paths tried:" >&2
	printf '       - %s\n' "${candidates[@]}" >&2
	echo "       Set VIBESTARTER_APP_DIR to the app repository root if it is elsewhere." >&2
	return 1
}

main() {
	local tauri_resources
	local resource_out
	local version

	tauri_resources="$(resolve_tauri_resources)"
	resource_out="$tauri_resources/$PLUGIN_ARTIFACT"
	version="$(tr -d '[:space:]' < "$ROJO_DIR/plugin/Version.txt")"
	echo "==> VibeStarter Sync plugin v$version"

	# Build the fork CLI once if its release binary is missing.
	if [[ ! -x "$ROJO_BIN" ]]; then
		echo "==> Fork rojo binary missing — building it (cargo build --release)…"
		(cd "$ROJO_DIR" && cargo build --release)
	fi

	echo "==> Building plugin ($PROJECT_FILE)…"
	mkdir -p "$(dirname "$CANONICAL_OUT")"
	(cd "$ROJO_DIR" && "$ROJO_BIN" build "$PROJECT_FILE" --output "$CANONICAL_OUT")

	cp "$CANONICAL_OUT" "$resource_out"

	echo "==> Embedded into the app:"
	ls -la "$CANONICAL_OUT" "$resource_out"
	echo
	echo "Done. Now commit the updated resources/$PLUGIN_ARTIFACT in the VibeStarter app repo to ship v$version."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
