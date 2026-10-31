#!/bin/bash
# Crea MiIsla.app a partir del paquete Swift. No necesita proyecto de Xcode.
#
#   ./build_app.sh                 -> firma "ad hoc" (gratis, funciona en tu Mac)
#   ./build_app.sh "Apple Development: Tu Nombre (XXXXXXXXXX)"
#                                  -> firma con tu Apple ID (Xcode > Settings > Accounts).
#                                     Con esta firma macOS RECUERDA los permisos entre versiones.
#   Para ver tus identidades:  security find-identity -v -p codesigning
#
# MISILA_VERSION=1.2.0 ./build_app.sh   -> pone esa versión en la app
#
# Después:  open MiIsla.app    (o arrástrala a la carpeta Aplicaciones)
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${1:--}"
APP="MiIsla.app"

echo "▸ Compilando (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Armando $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MiIsla" "$APP/Contents/MacOS/MiIsla"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# Versión (opcional)
if [ -n "${MISILA_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MISILA_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-$(date +%y%m%d%H%M)}" "$APP/Contents/Info.plist"
fi

# Icono de la app
if [ -d Packaging/AppIcon.iconset ]; then
  iconutil -c icns Packaging/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" || echo "  (no se pudo crear el icono, sigo sin él)"
fi

# Tus imágenes personales (carpeta Personal/, no se publica): se copian a donde la app las busca.
if ls Personal/*.png >/dev/null 2>&1; then
  mkdir -p "$HOME/Library/Application Support/MiIsla"
  cp Personal/*.png "$HOME/Library/Application Support/MiIsla/"
  echo "▸ Imágenes personales copiadas a ~/Library/Application Support/MiIsla"
fi

echo "▸ Firmando con: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$APP"

echo "✔ Listo: $(pwd)/$APP"
echo "  Ábrela con:  open \"$APP\""
