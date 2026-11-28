#!/bin/bash
# Installs Cairn for GNOME for this user only (no sudo): builds it, then puts
# the app in ~/.local/bin and its launcher and icon in ~/.local/share, so it
# shows up in the app grid. Remove with: linux/install.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/scalable/apps"

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$BIN/cairn-gnome" "$APPS/dev.cairn.Cairn.desktop" "$ICONS/dev.cairn.Cairn.svg"
    # Otherwise GTK's icon cache still lists the deleted icon.
    gtk4-update-icon-cache -q -t -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    update-desktop-database -q "$APPS" 2>/dev/null || true
    echo "Removed Cairn from the app grid."
    exit 0
fi

swift build -c release --product cairn-gnome
mkdir -p "$BIN" "$APPS" "$ICONS"
install -m 755 .build/release/cairn-gnome "$BIN/cairn-gnome"
install -m 644 linux/dev.cairn.Cairn.svg "$ICONS/dev.cairn.Cairn.svg"
sed "s|^Exec=cairn-gnome|Exec=$BIN/cairn-gnome|" linux/dev.cairn.Cairn.desktop > "$APPS/dev.cairn.Cairn.desktop"
gtk4-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
update-desktop-database -q "$APPS" 2>/dev/null || true
echo "Installed. Find Cairn in the app grid (it may take a moment to appear)."
