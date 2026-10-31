#!/bin/bash
# Genera dist/MiIsla-<versión>.zip listo para subir a GitHub Releases.
#   ./release.sh 1.1.0
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.1.0}"
IDENTITY="${2:--}"     # "-" = firma ad hoc (gratis). Con Developer ID: "Developer ID Application: …"

MISILA_VERSION="$VERSION" ./build_app.sh "$IDENTITY"

mkdir -p dist
ZIP="dist/MiIsla-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent MiIsla.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "✔ $ZIP"
echo "  Súbelo con:  gh release create v$VERSION $ZIP $ZIP.sha256 --title \"MiIsla $VERSION\" --notes-file CHANGELOG.md"
