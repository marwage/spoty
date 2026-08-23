#!/usr/bin/env bash
# Builds Spoty.app from the SwiftPM product and installs it to ~/Applications.
# Deliberately uses only CommandLineTools: no xcodebuild, no actool, no asset catalog.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Spoty"
BUNDLE_ID="com.marcelwagenlander.spoty"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP="$ROOT/.build/$APP_NAME.app"
ICON_SRC="$ROOT/Resources/icon-1024.png"
ICONSET="$ROOT/.build/AppIcon.iconset"
ICNS="$ROOT/.build/AppIcon.icns"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "Building release binary"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "error: $BIN not found" >&2; exit 1; }

if [[ ! -f "$ICON_SRC" ]]; then
    log "Rendering app icon"
    swift "$ROOT/Scripts/make-icon.swift" "$ICON_SRC"
fi

if [[ ! -f "$ICNS" || "$ICON_SRC" -nt "$ICNS" ]]; then
    log "Building AppIcon.icns"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for spec in "16 1" "16 2" "32 1" "32 2" "128 1" "128 2" "256 1" "256 2" "512 1" "512 2"; do
        read -r base scale <<< "$spec"
        px=$((base * scale))
        suffix=""; [[ $scale -eq 2 ]] && suffix="@2x"
        sips -z "$px" "$px" "$ICON_SRC" \
            --out "$ICONSET/icon_${base}x${base}${suffix}.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi

log "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature. --deep is deprecated and unnecessary: there are no nested
# code items in a single-binary app.
log "Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

log "Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR:?}/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app"

log "Done: $INSTALL_DIR/$APP_NAME.app"
