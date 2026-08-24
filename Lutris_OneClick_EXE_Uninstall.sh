#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/.local/share/applications"
SERVICE_DIR="$HOME/.local/share/kio/servicemenus"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/lutris-oneclick"

echo "Removing Lutris One-Click EXE integration..."

rm -f \
  "$BIN_DIR/lutris-exe-helper" \
  "$BIN_DIR/lutris-complete-game-remove" \
  "$APP_DIR/lutris-exe-installer.desktop" \
  "$APP_DIR/lutris-complete-game-remove.desktop" \
  "$APP_DIR/lutris-steam-shortcut-repair.desktop" \
  "$APP_DIR/lutris-oneclick-tools.desktop" \
  "$SERVICE_DIR/lutris-exe-update.desktop" \
  "$SERVICE_DIR/lutris-exe.desktop"

rm -rf "$DATA_DIR"
rm -rf "$HOME/.cache/lutris-exe-helper"

if command -v flatpak >/dev/null 2>&1 && flatpak info com.usebottles.bottles >/dev/null 2>&1; then
  for mime in \
    application/x-ms-dos-executable \
    application/x-msdownload \
    application/vnd.microsoft.portable-executable
  do
    xdg-mime default com.usebottles.bottles.desktop "$mime" >/dev/null 2>&1 || true
  done
fi

update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
kbuildsycoca6 >/dev/null 2>&1 || true

echo
echo "Done."
echo "Lutris, installed games, Wine prefixes and existing Steam game shortcuts were NOT removed."
