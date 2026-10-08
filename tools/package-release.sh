#!/bin/bash
#
# Baut Kastellan zur Weitergabe: Archiv, Export mit Developer ID (von Xcode über das angemeldete
# Entwicklerkonto signiert), Notarisierung, Stapling, dann ZIP, DMG, Prüfsummen und den Sparkle-Feed
# appcast.xml (DMG signiert mit dem Ed25519-Schlüssel „kastellan“ aus dem Schlüsselbund).
#
#   tools/package-release.sh                          # notarisiert über das Xcode-Konto
#   NOTARY_PROFILE=kastellan-notary tools/package-release.sh   # notarisiert über notarytool-Profil
#   SKIP_NOTARIZE=1 tools/package-release.sh          # nur signieren (Empfänger: Rechtsklick → Öffnen)
#
# Voraussetzung: in Xcode angemeldetes Konto des Teams aus project.yml mit Recht auf Developer-ID-
# Zertifikate, und der Sparkle-Schlüssel im Schlüsselbund (einmalig: generate_keys --account kastellan). Ein notarytool-Profil legt man einmalig an mit
#   xcrun notarytool store-credentials kastellan-notary --apple-id <apple-id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\([^"]*\)".*/\1/p' project.yml | head -1)
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *"\([^"]*\)".*/\1/p' project.yml | head -1)
WORK="build/archive"
DD="build/DerivedData"
ARCHIVE="$WORK/Kastellan.xcarchive"
OUT="build/release/Kastellan-$VERSION"
LOGS=$(mktemp -d)

filter() { grep -v -E "DVTPlugIn|CoreSimulator|No locator|Progress [0-9]+ %" "$1" | grep -E "$2" || true; }

echo "==> Version $VERSION ($BUILD), Team $TEAM"
xcodegen generate >/dev/null
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"

echo "==> Archiv (Release)"
xcodebuild -project Kastellan.xcodeproj -scheme Kastellan -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$DD" -skipPackagePluginValidation -allowProvisioningUpdates archive > "$LOGS/archive.log" 2>&1 || true
filter "$LOGS/archive.log" "error:|ARCHIVE (SUCCEEDED|FAILED)"
grep -q "ARCHIVE SUCCEEDED" "$LOGS/archive.log" || { echo "Archiv fehlgeschlagen (Log: $LOGS/archive.log)"; exit 1; }

export_opts() {
  cat > "$LOGS/export-$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>destination</key><string>$1</string>
</dict></plist>
PLIST
  echo "$LOGS/export-$1.plist"
}

APP=""
if [ -z "${SKIP_NOTARIZE:-}" ] && [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "==> Export mit Developer ID und Upload zur Notarisierung (Xcode-Konto)"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$(export_opts upload)" \
    -exportPath "$WORK/upload" -allowProvisioningUpdates > "$LOGS/upload.log" 2>&1 || true
  grep -q "EXPORT SUCCEEDED" "$LOGS/upload.log" || { filter "$LOGS/upload.log" "error"; echo "Upload fehlgeschlagen (Log: $LOGS/upload.log)"; exit 1; }
  echo "==> Warte auf Apple (bis 30 Minuten)"
  for i in $(seq 1 60); do
    xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$WORK/notarized" > "$LOGS/notarized.log" 2>&1 || true
    [ -d "$WORK/notarized/Kastellan.app" ] && { APP="$WORK/notarized/Kastellan.app"; break; }
    if grep -q -i -E "invalid|rejected" "$LOGS/notarized.log"; then filter "$LOGS/notarized.log" "."; echo "Notarisierung abgelehnt"; exit 1; fi
    sleep 30
  done
  [ -n "$APP" ] || { echo "Notarisierung nach 30 Minuten nicht fertig (Log: $LOGS/notarized.log)"; exit 1; }
else
  echo "==> Export mit Developer ID"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$(export_opts export)" \
    -exportPath "$WORK/export" -allowProvisioningUpdates > "$LOGS/export.log" 2>&1 || true
  grep -q "EXPORT SUCCEEDED" "$LOGS/export.log" || { filter "$LOGS/export.log" "error"; echo "Export fehlgeschlagen (Log: $LOGS/export.log)"; exit 1; }
  APP="$WORK/export/Kastellan.app"
fi

ditto "$APP" "$OUT/Kastellan.app"
if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${SKIP_NOTARIZE:-}" ]; then
  echo "==> Notarisierung über notarytool ($NOTARY_PROFILE)"
  ditto -c -k --keepParent "$OUT/Kastellan.app" "$LOGS/submit.zip"
  xcrun notarytool submit "$LOGS/submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/Kastellan.app"
fi

echo "==> Prüfen"
codesign --verify --deep --strict "$OUT/Kastellan.app" && echo "    Signatur ok"
codesign -dvv "$OUT/Kastellan.app" 2>&1 | grep "Authority=Developer ID Application" || echo "    Hinweis: nicht mit Developer ID signiert"
spctl --assess --type execute -vv "$OUT/Kastellan.app" 2>&1 | head -2 || true

NOTARIZED=0
xcrun stapler validate "$OUT/Kastellan.app" >/dev/null 2>&1 && NOTARIZED=1
cat > "$OUT/LIESMICH.txt" <<TXT
Kastellan $VERSION

Installation
1. Kastellan.app in den Ordner Programme ziehen und starten.
$( [ $NOTARIZED = 1 ] && echo "   Die App ist von Apple notarisiert und startet ohne Warnung." || echo "   Beim ersten Start: Rechtsklick auf Kastellan.app, „Öffnen“ wählen und bestätigen (nicht notarisiert)." )
2. In der App unter Verbindungen den ersten Hoster anlegen (All-Inkl, Cloudflare, Hetzner,
   hosting.de, Mittwald, Hostinger, Namecheap). Zugangsdaten landen im Schlüsselbund.
3. Unter MCP-Clients einen Token für Claude Code oder Claude Desktop ausstellen und die
   Konfiguration schreiben lassen. Rechte je Verbindung unter Rechte, Freigaben unter Freigaben.

Voraussetzungen: macOS 14 oder neuer.
Der MCP-Server liegt in Kastellan.app/Contents/MacOS/kastellan-mcp und wird von der App eingerichtet.
Änderungen: siehe CHANGELOG.md.
TXT
cp CHANGELOG.md "$OUT/CHANGELOG.md"

echo "==> ZIP und DMG"
ZIP="build/release/Kastellan-$VERSION.zip"
DMG="build/release/Kastellan-$VERSION.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$OUT/Kastellan.app" "$ZIP"
STAGE=$(mktemp -d)
ditto "$OUT/Kastellan.app" "$STAGE/Kastellan.app"
cp "$OUT/LIESMICH.txt" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
hdiutil create -volname "Kastellan $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

echo "==> Sparkle-Feed"
SIGN_UPDATE=$(find "$DD/SourcePackages/artifacts" -path '*/old_dsa_scripts' -prune -o -type f -name sign_update -print 2>/dev/null | head -1)
[ -x "$SIGN_UPDATE" ] || { echo "sign_update von Sparkle nicht gefunden"; exit 1; }
SIG_LINE=$("$SIGN_UPDATE" --account kastellan "$DMG")
ED_SIG=$(printf '%s' "$SIG_LINE" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')
LENGTH=$(printf '%s' "$SIG_LINE" | sed -nE 's/.*length="([0-9]+)".*/\1/p')
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || { echo "sign_update-Ausgabe nicht lesbar: $SIG_LINE"; exit 1; }
NOTES=$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {f=1; next} f && /^## \[/ {exit} f' CHANGELOG.md)
OUTPUT_PATH="build/release/appcast.xml" VERSION="$VERSION" BUILD="$BUILD" \
  DMG_URL="https://github.com/staude/kastellan/releases/download/v$VERSION/Kastellan-$VERSION.dmg" \
  DMG_LENGTH="$LENGTH" DMG_ED_SIGNATURE="$ED_SIG" PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" \
  NOTES_MD="$NOTES" NOTES_URL="https://github.com/staude/kastellan/releases/tag/v$VERSION" \
  python3 tools/appcast.py
echo "    build/release/appcast.xml"

(cd build/release && shasum -a 256 "Kastellan-$VERSION.zip" "Kastellan-$VERSION.dmg" | tee "Kastellan-$VERSION.sha256")
echo "Fertig: $DMG, $ZIP, build/release/appcast.xml (notarisiert: $([ $NOTARIZED = 1 ] && echo ja || echo nein))"
