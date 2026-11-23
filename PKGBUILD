# Maintainer: Akshay Bapat <https://github.com/akshaybapat6365>
pkgname=omarchy-overview
pkgver=0.1.0
pkgrel=1
pkgdesc='macOS Mission Control-class workspace & window overview for Hyprland and Quickshell'
arch=('any')
url='https://github.com/akshaybapat6365/omarchy-overview'
license=('MIT')
depends=('quickshell' 'hyprland' 'qt6-declarative' 'qt6-5compat')
optdepends=('lua: run unit test suite')
source=()

package() {
  local srcroot="${startdir}"
  local dest="$pkgdir/usr/share/$pkgname"

  install -dm755 "$dest"/{backends,ops,shaders,hypr}
  for f in shell.qml Scene.qml SpacesBar.qml DeskTile.qml WindowCard.qml \
           DragController.qml ResultPill.qml Gesture.js Layout.js Ops.js Desks.js \
           backends/HyprlandBackend.qml backends/MockBackend.qml \
           ops/ovops.lua shaders/rounded.frag shaders/rounded.frag.qsb \
           hypr/overview.lua hypr/input.lua; do
    install -Dm644 "$srcroot/$f" "$dest/$f"
  done

  install -Dm644 "$srcroot/systemd/omarchy-overview.service" \
    "$pkgdir/usr/lib/systemd/user/omarchy-overview.service"
  install -Dm644 "$srcroot/LICENSE" \
    "$pkgdir/usr/share/licenses/$pkgname/LICENSE"

  install -dm755 "$pkgdir/usr/bin"
  cat >"$pkgdir/usr/bin/omarchy-overview-setup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SHARE="/usr/share/omarchy-overview"
XDG_CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
PREFIX="${1:-$XDG_CFG/quickshell/overview}"
HYPR_DIR="$XDG_CFG/hypr"

mkdir -p "$PREFIX"/{backends,ops,shaders} "$HYPR_DIR"
for f in shell.qml Scene.qml SpacesBar.qml DeskTile.qml WindowCard.qml \
         DragController.qml ResultPill.qml Gesture.js Layout.js Ops.js Desks.js \
         backends/HyprlandBackend.qml backends/MockBackend.qml \
         ops/ovops.lua shaders/rounded.frag shaders/rounded.frag.qsb; do
  install -m 0644 "$SHARE/$f" "$PREFIX/$f"
done

if [[ -f "$HYPR_DIR/overview.lua" ]] && ! cmp -s "$SHARE/hypr/overview.lua" "$HYPR_DIR/overview.lua"; then
  cp -p "$HYPR_DIR/overview.lua" "$HYPR_DIR/overview.lua.bak.$(date +%Y%m%d-%H%M%S)"
fi
install -m 0644 "$SHARE/hypr/overview.lua" "$HYPR_DIR/overview.lua"
echo "Installed omarchy-overview to $PREFIX and $HYPR_DIR/overview.lua."
echo "Enable with: systemctl --user enable --now omarchy-overview.service"
EOF
  chmod 0755 "$pkgdir/usr/bin/omarchy-overview-setup"
}
