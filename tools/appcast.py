#!/usr/bin/env python3
"""Erzeugt den Sparkle-Feed (appcast.xml) für genau eine Version, als Release-Asset neben dem DMG.

Aufruf über tools/package-release.sh; Werte kommen als Umgebungsvariablen:
OUTPUT_PATH, VERSION, BUILD, DMG_URL, DMG_LENGTH, DMG_ED_SIGNATURE, PUB_DATE, NOTES_MD (optional), NOTES_URL.
Vorbild: TorroMail scripts/_appcast_create.py.
"""

import html
import os
import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)
FEED_URL = "https://github.com/staude/kastellan/releases/latest/download/appcast.xml"


def required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"Fehler: {name} fehlt")
    return value


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)


def markdown_to_html(markdown: str) -> str:
    out: list[str] = []
    in_list = False
    for raw in markdown.splitlines():
        line = raw.rstrip()
        if not line.strip():
            if in_list:
                out.append("</ul>"); in_list = False
            continue
        heading = re.match(r"(#{1,6})\s+(.*)", line)
        if heading:
            if in_list:
                out.append("</ul>"); in_list = False
            level = min(len(heading.group(1)) + 1, 6)
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            continue
        bullet = re.match(r"\s*[-*]\s+(.*)", line)
        if bullet:
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append(f"<li>{inline(bullet.group(1))}</li>")
            continue
        if in_list:
            out.append("</ul>"); in_list = False
        out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main() -> None:
    output = Path(required("OUTPUT_PATH"))
    version = required("VERSION")
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Kastellan Updates"
    ET.SubElement(channel, "link").text = FEED_URL
    ET.SubElement(channel, "description").text = "Signierte Kastellan-Versionen"
    ET.SubElement(channel, "language").text = "de"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Version {version}"
    ET.SubElement(item, "pubDate").text = required("PUB_DATE")
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = required("BUILD")
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "14.0"
    notes = os.environ.get("NOTES_MD", "").strip()
    if notes:
        ET.SubElement(item, "description").text = markdown_to_html(notes)
    else:
        ET.SubElement(item, f"{{{SPARKLE_NS}}}releaseNotesLink").text = required("NOTES_URL")
    ET.SubElement(item, "enclosure", {
        "url": required("DMG_URL"),
        f"{{{SPARKLE_NS}}}edSignature": required("DMG_ED_SIGNATURE"),
        "length": required("DMG_LENGTH"),
        "type": "application/octet-stream",
    })
    output.parent.mkdir(parents=True, exist_ok=True)
    tree = ET.ElementTree(rss)
    ET.indent(tree, space="  ")
    tree.write(output, encoding="UTF-8", xml_declaration=True)


if __name__ == "__main__":
    main()
