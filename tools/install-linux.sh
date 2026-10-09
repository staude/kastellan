#!/usr/bin/env bash
# Installiert Kastellan unter Linux für den aktuellen Benutzer, ohne root:
#
#   kastellan      Terminal-Oberfläche
#   kastellan-mcp  MCP-Server, den Claude startet
#
# Beide landen nebeneinander in $PREFIX/bin (Standard ~/.local). Die Oberfläche findet den Server
# neben sich und trägt diesen Pfad ein, wenn ein MCP-Client eingerichtet wird.
#
#   tools/install-linux.sh                  aus diesem Checkout bauen (braucht Swift 6) und installieren
#   tools/install-linux.sh --release [v]    fertige Programme vom GitHub-Release laden (Standard: neuestes)
#   tools/install-linux.sh --uninstall      Programme und Hintergrundprüfung wieder entfernen
#   PREFIX=/usr/local tools/install-linux.sh
#   JOBS=2 tools/install-linux.sh           weniger parallele Compiler-Läufe (wenig Arbeitsspeicher)
#
# Daten (Verbindungen, Rechte, Protokoll) liegen in ${XDG_STATE_HOME:-~/.local/state}/kastellan und
# werden hier nie angefasst; Zugangsdaten liegen im Secret Service des Desktops.
set -euo pipefail

prefix="${PREFIX:-$HOME/.local}"
bin="$prefix/bin"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="staude/kastellan"

if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ -x "$bin/kastellan" ]]; then "$bin/kastellan" autocheck disable >/dev/null 2>&1 || true; fi
    rm -f "$bin/kastellan" "$bin/kastellan-mcp"
    echo "kastellan und kastellan-mcp aus $bin entfernt, Hintergrundprüfung abgeschaltet."
    echo "Die Daten in ${XDG_STATE_HOME:-$HOME/.local/state}/kastellan sind unverändert."
    echo "Eingerichtete MCP-Clients nennen den entfernten Server noch in ihrer Konfiguration;"
    echo "den Eintrag \"kastellan-…\" dort von Hand entfernen."
    exit 0
fi

# Nicht fatal: ohne secret-tool lässt sich nur keine Verbindung mit Zugangsdaten anlegen.
if ! command -v secret-tool >/dev/null; then
    echo "Hinweis: secret-tool fehlt. Kastellan legt Zugangsdaten im Secret Service ab und braucht es" >&2
    echo "         (Debian/Ubuntu: apt install libsecret-tools, Fedora: dnf install libsecret," >&2
    echo "         Arch: pacman -S libsecret) und einen laufenden Schlüsselbund wie gnome-keyring." >&2
fi

case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "Nicht unterstützte Architektur: $(uname -m)" >&2; exit 1 ;;
esac

if [[ "${1:-}" == "--release" ]]; then
    version="${2:-}"
    if [[ -z "$version" ]]; then
        url="https://github.com/$repo/releases/latest/download/kastellan-linux-$arch.tar.gz"
    else
        url="https://github.com/$repo/releases/download/v${version#v}/kastellan-linux-$arch.tar.gz"
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "Lade $url …"
    curl -fsSL "$url" -o "$tmp/kastellan.tar.gz"
    tar -xzf "$tmp/kastellan.tar.gz" -C "$tmp"
    src="$tmp/kastellan-linux-$arch"
else
    if ! command -v swift >/dev/null; then
        echo "swift wurde nicht gefunden. Swift 6 installieren (https://swift.org/install) oder" >&2
        echo "fertige Programme laden: tools/install-linux.sh --release" >&2
        exit 1
    fi
    echo "Baue (release) …"
    swift build -c release --static-swift-stdlib --package-path "$root" ${JOBS:+-j "$JOBS"}
    src="$root/.build/release"
fi

install -Dm755 "$src/kastellan" "$bin/kastellan"
install -Dm755 "$src/kastellan-mcp" "$bin/kastellan-mcp"
# Debug-Informationen entfernen, wie in der CI: aus rund 100 MB je Programm werden etwa 60 MB.
if command -v strip >/dev/null; then strip "$bin/kastellan" "$bin/kastellan-mcp"; fi

echo
echo "$("$bin/kastellan" --version) nach $bin installiert."
case ":$PATH:" in
    *":$bin:"*) echo "Start: kastellan" ;;
    *) echo "$bin steht nicht im PATH. Start: $bin/kastellan" ;;
esac
echo "Hintergrundprüfung (Freigaben melden, Verbindungen prüfen): kastellan autocheck enable"
