#!/usr/bin/env python3
"""Macht aus dem Roh-Dump von kas-probe.php (--dump) gekürzte, maskierte Test-Fixtures.

Aufruf: python3 tools/kas-fixtures.py <dump-verzeichnis>
Ziel:   Packages/KastellanCore/Tests/KastellanCoreTests/Fixtures/kas/

Arrays in ReturnInfo werden auf zwei Einträge gekürzt, Tokens in URLs maskiert.
Das Roh-Verzeichnis bleibt unangetastet und wird erst nach Sichtprüfung von Hand gelöscht.
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, "Packages", "KastellanCore", "Tests", "KastellanCoreTests", "Fixtures", "kas")

KEEP = {
    "01-kasauth-request.xml": "kasauth-request.xml",
    "01-kasauth-response.xml": "kasauth-response.xml",
    "03-get_dkim-request.xml": "get_dkim-request.xml",
    "03-get_dkim-response.xml": "get_dkim-response.xml",
    "11-get_dns_settings-fault-response.xml": "fault-zone_not_found.xml",
    "12-delete_session-response.xml": "delete_session-response.xml",
}
TRIM = ["02-get_domains", "04-get_mailaccounts", "05-get_mailforwards", "06-get_subdomains",
        "07-get_ftpusers", "08-get_databases", "09-get_cronjobs", "10-get_dns_settings"]

ARRAY_RE = re.compile(r'(<value SOAP-ENC:arrayType="ns2:Map\[)(\d+)(\]" xsi:type="SOAP-ENC:Array">)(.*?)(</value></item></value></item></return>)', re.S)


def split_items(body: str) -> list[str]:
    """Zerlegt den Inhalt eines SOAP-Arrays in seine Top-Level-<item>-Elemente."""
    items, depth, start = [], 0, None
    for m in re.finditer(r"<item(?:\s[^>]*)?>|</item>", body):
        if m.group(0).startswith("</"):
            depth -= 1
            if depth == 0:
                items.append(body[start:m.end()])
        else:
            if depth == 0:
                start = m.start()
            depth += 1
    return items


def mask(text: str) -> str:
    return re.sub(r"([?&](?:token|key|pass|secret|apikey)=)[^&<\s]+", r"\1***", text, flags=re.I)


def main(src: str) -> None:
    os.makedirs(DST, exist_ok=True)
    for a, b in KEEP.items():
        shutil.copy(os.path.join(src, a), os.path.join(DST, b))
    for name in TRIM:
        raw = open(os.path.join(src, name + "-response.xml"), encoding="utf-8").read()
        m = ARRAY_RE.search(raw)
        if not m:
            raise SystemExit(f"{name}: ReturnInfo-Array nicht gefunden")
        items = split_items(m.group(4))[:2]
        out = raw[: m.start()] + m.group(1) + str(len(items)) + m.group(3) + "".join(items) + m.group(5) + raw[m.end():]
        open(os.path.join(DST, name[3:] + "-response.xml"), "w", encoding="utf-8").write(mask(out))
    print("Fixtures geschrieben nach", DST)
    for f in sorted(os.listdir(DST)):
        print("  ", f, os.path.getsize(os.path.join(DST, f)), "Bytes")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
