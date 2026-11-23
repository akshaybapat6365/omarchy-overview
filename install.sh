#!/usr/bin/env bash
# install.sh — Portable installer for omarchy-overview (Quickshell + Hyprland Lua).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XDG_CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

PREFIX="$XDG_CFG/quickshell/overview"
HYPR_DIR="$XDG_CFG/hypr"
SYSTEMD_DIR="$XDG_CFG/systemd/user"
WIRE_HYPR=0
INSTALL_SYSTEMD=0
NO_RESTART=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Install omarchy-overview Quickshell UI and Hyprland gesture stream module.

Options:
  --prefix DIR       Target Quickshell config directory
                     (default: ${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/overview)
  --hypr-dir DIR     Target Hyprland config directory
                     (default: ${XDG_CONFIG_HOME:-$HOME/.config}/hypr)
  --wire-hypr        Append an idempotent hypr/overview.lua loader & layer rule
                     snippet to $HYPR_DIR/hyprland.lua (with timestamped backup)
  --systemd          Install systemd user unit (omarchy-overview.service)
  --no-restart       Do not restart an active omarchy-overview.service
  -h, --help         Show this help message
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
    --wire-hypr)
      WIRE_HYPR=1; shift
      ;;
    --systemd)
      INSTALL_SYSTEMD=1; shift
      ;;
    --no-restart)
      NO_RESTART=1; shift
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

echo "==> Checking runtime dependencies"
for bin in qs hyprctl; do
  if command -v "$bin" >/dev/null 2>&1; then
    echo "    [ok]   $bin -> $(command -v "$bin")"
  else
    echo "    [warn] $bin not found in PATH (required at runtime on Hyprland)" >&2
  fi
done

WAS_ACTIVE=0
if (( NO_RESTART == 0 )) && command -v systemctl >/dev/null 2>&1; then
  if systemctl --user is-active --quiet omarchy-overview.service 2>/dev/null; then
    WAS_ACTIVE=1
    echo "==> Stopping running omarchy-overview.service before atomic file update"
    systemctl --user stop omarchy-overview.service
  fi
fi

echo "==> Installing Quickshell overview into $PREFIX"
mkdir -p "$PREFIX/backends" "$PREFIX/ops" "$PREFIX/shaders"

RUNTIME_FILES=(
  shell.qml
  Scene.qml
  SpacesBar.qml
  DeskTile.qml
  WindowCard.qml
  DragController.qml
  ResultPill.qml
  Gesture.js
  Layout.js
  Ops.js
  Desks.js
  backends/HyprlandBackend.qml
  backends/MockBackend.qml
  ops/ovops.lua
  shaders/rounded.frag
  shaders/rounded.frag.qsb
)

for rel in "${RUNTIME_FILES[@]}"; do
  install -m 0644 "$SCRIPT_DIR/$rel" "$PREFIX/$rel"
done

echo "==> Installing Hyprland gesture stream module into $HYPR_DIR/overview.lua"
mkdir -p "$HYPR_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$HYPR_DIR/overview.lua" ]] && ! cmp -s "$SCRIPT_DIR/hypr/overview.lua" "$HYPR_DIR/overview.lua"; then
  BACKUP="$HYPR_DIR/overview.lua.bak.$STAMP"
  cp -p "$HYPR_DIR/overview.lua" "$BACKUP"
  echo "    [backup] Saved previous overview.lua -> $BACKUP"
fi
install -m 0644 "$SCRIPT_DIR/hypr/overview.lua" "$HYPR_DIR/overview.lua"

if (( INSTALL_SYSTEMD == 1 )); then
  echo "==> Installing systemd user service into $SYSTEMD_DIR/omarchy-overview.service"
  mkdir -p "$SYSTEMD_DIR"
  install -m 0644 "$SCRIPT_DIR/systemd/omarchy-overview.service" "$SYSTEMD_DIR/omarchy-overview.service"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
fi

if (( WIRE_HYPR == 1 )); then
  TARGET_LUA="$HYPR_DIR/hyprland.lua"
  MARKER="# omarchy-overview-wire"
  if [[ -f "$TARGET_LUA" ]] && grep -qF "hypr.overview" "$TARGET_LUA"; then
    echo "==> Hyprland Lua config already references hypr.overview ($TARGET_LUA); skipping --wire-hypr"
  else
    if [[ -f "$TARGET_LUA" ]]; then
      cp -p "$TARGET_LUA" "$TARGET_LUA.bak.$STAMP"
      echo "    [backup] Saved $TARGET_LUA -> $TARGET_LUA.bak.$STAMP"
    fi
    cat >>"$TARGET_LUA" <<'EOF'

-- omarchy-overview: live 3/4-finger touchpad gesture stream + zero-anim overlay rule
do
  local p = package.searchpath("hypr.overview", package.path)
  local chunk = p and loadfile(p)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then package.loaded["hypr.overview"] = mod end
  end
end
hl.layer_rule({ match = { namespace = "^omarchy-overview$" }, no_anim = true })
EOF
    echo "==> Wired hypr/overview.lua loader into $TARGET_LUA"
  fi
fi

if (( WAS_ACTIVE == 1 )); then
  echo "==> Restarting omarchy-overview.service"
  systemctl --user start omarchy-overview.service
fi

cat <<EOF

Install complete!

Next steps (if you did not pass --wire-hypr):
  1. Add to ~/.config/hypr/hyprland.lua (or ~/.config/hypr/input.lua):
       pcall(function() local p = package.searchpath("hypr.overview", package.path); if p then package.loaded["hypr.overview"] = dofile(p) end end)
       hl.layer_rule({ match = { namespace = "^omarchy-overview$" }, no_anim = true })

  2. Start the overview daemon in ~/.config/hypr/autostart.lua (or enable systemd):
       hl.exec_once("qs -c overview")
       # Or: ./install.sh --systemd && systemctl --user enable --now omarchy-overview.service

  3. Test via IPC:
       qs ipc -c overview call overview toggle
EOF
