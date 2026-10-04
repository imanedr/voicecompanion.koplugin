#!/bin/sh
# Check sentence splitting and read-aloud groups on a real book, using
# KOReader's own crengine (no device, no display).
#
#   tools/crengine_check.sh BOOK.epub [sentences|groups|stats] [PAGE] [N]
#
# KOREADER: KOReader's install dir (the one with luajit and frontend/),
# e.g. from an extracted AppImage:
#   ./koreader-*.AppImage --appimage-extract  ->  squashfs-root/usr/lib/koreader
set -eu
: "${KOREADER:?set KOREADER to KOReader's install dir (with luajit and frontend/)}"
book=$(realpath "$1")
plugin=$(cd "$(dirname "$0")/.." && pwd)
home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/.config/koreader/cache/cr3cache"
cd "$KOREADER"
HOME="$home" PLUGIN="$plugin" BOOK="$book" MODE="${2:-sentences}" PAGE="${3:-5}" N="${4:-}" \
    SDL_VIDEODRIVER=dummy ./luajit "$plugin/tools/crengine_check.lua" 2>&1 >/dev/null
