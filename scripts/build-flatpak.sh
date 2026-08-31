#!/usr/bin/env bash
# Build the Zcode Flatpak from scratch.
#
# Usage: ./build-flatpak.sh [options]
#   --install   Install the build into the user installation
#   --run       Run the app after a successful build (implies --install)
#   --bundle    Export a single-file bundle (zcode.flatpak)
#   --keep      Reuse build caches instead of starting clean
#   -h, --help  Show this help
#
# With no options it does a clean build into build-dir/ without installing.
# It pulls the GNOME runtime/SDK the manifest asks for from Flathub; everything
# else (sources, patches, bundled deps) is built from this checkout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="org.senonide.zcode.json"
APP_ID="org.senonide.zcode"
BUILD_DIR="build-dir"
REPO_DIR="repo"
BUNDLE="zcode.flatpak"

install=0 run=0 bundle=0 keep=0
usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --run)     run=1; install=1 ;;
        --bundle)  bundle=1 ;;
        --keep)    keep=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

command -v flatpak >/dev/null 2>&1 ||
    { echo "error: flatpak is not installed" >&2; exit 1; }

# flatpak-builder may be a native binary or the org.flatpak.Builder Flatpak
# (the recommended install nowadays); support both.
if command -v flatpak-builder >/dev/null 2>&1; then
    BUILDER=(flatpak-builder)
elif flatpak info org.flatpak.Builder >/dev/null 2>&1; then
    BUILDER=(flatpak run org.flatpak.Builder)
else
    echo "error: flatpak-builder not found" >&2
    echo "       install it with: flatpak install flathub org.flatpak.Builder" >&2
    exit 1
fi

# Match the runtime the manifest declares rather than hardcoding the version.
runtime_version="$(sed -n 's/.*"runtime-version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")"
: "${runtime_version:?could not read runtime-version from $MANIFEST}"

flatpak remote-add --user --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user --noninteractive --or-update flathub \
    "org.gnome.Platform//$runtime_version" "org.gnome.Sdk//$runtime_version"

# Start from a clean slate unless --keep was given; the .flatpak-builder cache
# is left untouched so module rebuilds (cmark, vte, zig) stay fast.
[ "$keep" -eq 0 ] && rm -rf "$BUILD_DIR" "$REPO_DIR"

builder_args=(--force-clean --user)
[ "$install" -eq 1 ] && builder_args+=(--install)
[ "$bundle" -eq 1 ] && builder_args+=(--repo="$REPO_DIR")
"${BUILDER[@]}" "${builder_args[@]}" "$BUILD_DIR" "$MANIFEST"

if [ "$bundle" -eq 1 ]; then
    flatpak build-bundle "$REPO_DIR" "$BUNDLE" "$APP_ID"
    echo "wrote $BUNDLE"
fi

[ "$run" -eq 1 ] && exec flatpak run "$APP_ID"
echo "Flatpak build finished."
