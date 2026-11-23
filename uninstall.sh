#!/usr/bin/env bash
# uninstall.sh — Cleanly remove omarchy-overview files and print restore hints.
set -euo pipefail

XDG_CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
PREFIX="$XDG_CFG/quickshell/overview"
HYPR_DIR="$XDG_CFG/hypr"
SYSTEMD_DIR="$XDG_CFG/systemd/user"

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [OPTIONS]

Remove omarchy-overview Quickshell files, Hyprland module, and optional user unit.

Options:
  --prefix DIR     Quickshell overview directory (default: ~/.config/quickshell/overview)
  --hypr-dir DIR   Hyprland config directory (default: ~/.config/hypr)
  -h, --help       Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || { echo "error: --prefix requires a path" >&2; exit 2; }
      PREFIX="$2"; shift 2
      ;;
    --hypr-dir)
      [[ $# -ge 2 ]] || { echo "error: --hypr-dir requires a path" >&2; exit 2; }
      HYPR_DIR="$2"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now omarchy-overview.service 2>/dev/null || true
fi

if [[ -d "$PREFIX" ]]; then
  rm -rf "$PREFIX"
  echo "Removed: $PREFIX"
fi

if [[ -f "$HYPR_DIR/overview.lua" ]]; then
  rm -f "$HYPR_DIR/overview.lua"
  echo "Removed: $HYPR_DIR/overview.lua"
fi

if [[ -f "$SYSTEMD_DIR/omarchy-overview.service" ]]; then
  rm -f "$SYSTEMD_DIR/omarchy-overview.service"
  echo "Removed: $SYSTEMD_DIR/omarchy-overview.service"
  command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null || true
fi

shopt -s nullglob
backups=("$HYPR_DIR"/overview.lua.bak.* "$HYPR_DIR"/hyprland.lua.bak.*)
if (( ${#backups[@]} > 0 )); then
  echo
  echo "Timestamped backups found in $HYPR_DIR:"
  for b in "${backups[@]}"; do
    echo "  $b"
  done
  echo "Restore manually with 'cp -p <backup> <target>' if needed."
fi

echo
echo "Note: Remove any hypr.overview loader or 'qs -c overview' lines you added to"
echo "      $HYPR_DIR/hyprland.lua, input.lua, or autostart.lua."
