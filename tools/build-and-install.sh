#!/bin/bash
#
# Baut Kastellan signiert (Apple Development, Team aus project.yml) und installiert die App nach /Applications.
# Signatur ist nötig, damit App und kastellan-mcp dieselben Schlüsselbund-Einträge lesen dürfen.
#
#   tools/build-and-install.sh            # Debug-Build nach /Applications/Kastellan.app
#   tools/build-and-install.sh --release  # Release-Build
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=Debug
[ "${1:-}" = "--release" ] && CONFIG=Release
DD="build/DerivedData"

echo "==> xcodegen generate"
xcodegen generate >/dev/null

echo "==> xcodebuild ($CONFIG, signiert)"
LOG=$(mktemp)
xcodebuild -project Kastellan.xcodeproj -scheme Kastellan -configuration "$CONFIG" \
  -destination 'platform=macOS' -derivedDataPath "$DD" -skipPackagePluginValidation \
  -allowProvisioningUpdates build > "$LOG" 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$LOG" || true
if ! grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo "Build fehlgeschlagen, Installation abgebrochen (Log: $LOG)"
  exit 1
fi

APP="$DD/Build/Products/$CONFIG/Kastellan.app"
[ -d "$APP" ] || { echo "Build fehlgeschlagen, $APP fehlt"; exit 1; }

echo "==> Beende laufende Instanzen"
for i in 1 2 3 4 5; do
  pkill -x Kastellan 2>/dev/null || true
  sleep 1
  pgrep -x Kastellan >/dev/null || break
done
pkill -9 -x Kastellan 2>/dev/null || true

echo "==> Kopiere nach /Applications/Kastellan.app"
rm -rf /Applications/Kastellan.app
ditto "$APP" /Applications/Kastellan.app

echo "==> Signatur prüfen"
codesign --verify --deep --strict /Applications/Kastellan.app && echo "    ok"

echo "==> Starte App"
open /Applications/Kastellan.app
echo "Fertig. MCP-Binary: /Applications/Kastellan.app/Contents/MacOS/kastellan-mcp"
