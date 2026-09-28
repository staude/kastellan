#!/bin/bash
#
# Kastellan — Setup für Entwickler. Einmalig aus dem Projekt-Root ausführen:
#   ./setup.sh
#
# Prüft die Toolchain und erzeugt das Xcode-Projekt aus project.yml.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Prüfe Voraussetzungen"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "    xcodegen fehlt. Installiere mit:  brew install xcodegen"
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "    Xcode fehlt. Bitte Xcode 16 oder neuer installieren."
  exit 1
fi
find . -name ".DS_Store" -delete 2>/dev/null || true

echo "==> Generiere Xcode-Projekt aus project.yml"
xcodegen generate

echo ""
echo "Fertig. Nächste Schritte:"
echo "  (cd Packages/KastellanCore && swift test)"
echo "  xcodebuild -project Kastellan.xcodeproj -scheme Kastellan -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build"
echo "  Für einen signierten Build DEVELOPMENT_TEAM in project.yml auf das eigene Team setzen und tools/build-and-install.sh ausführen."
