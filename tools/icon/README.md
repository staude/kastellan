# App-Icon

`kastellan.svg` ist die Quelle (1024 × 1024, macOS-Kachel mit Zinnenmauer, Torbogen und goldenem Schlüssel).

Alle Größen neu erzeugen:

```bash
swift tools/icon/render-icon.swift tools/icon/kastellan.svg Kastellan/Assets.xcassets/AppIcon.appiconset
```

Das Skript nutzt AppKit zum Rastern, braucht also keine Zusatzwerkzeuge.
