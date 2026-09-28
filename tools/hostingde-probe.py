#!/usr/bin/env python3
"""Ruft Find-Methoden der hosting.de-API auf und legt anonymisierte Antworten als Fixtures ab.

Aufruf:  HOSTINGDE_API_KEY=... tools/hostingde-probe.py [--out DIR] [--account ID] [--base URL] [--dump]

Ohne --out werden nur Anzahl und Status je Methode gezeigt. Mit --dump geht die rohe Antwort
(mit Key entfernt) nach stdout. Anonymisierung: Domains → example.com/example.net, IDs bleiben,
E-Mail-Lokalteile → user1, user2 …, IP-Adressen → 192.0.2.x / 2001:db8::x.
"""
import argparse, ipaddress, json, os, re, sys, urllib.request

BASE = "https://secure.hosting.de/api"
METHODS = [
    ("dns", "zoneConfigsFind"), ("dns", "zonesFind"), ("dns", "recordsFind"),
    ("email", "mailboxesFind"), ("email", "domainSettingsFind"),
    ("webhosting", "webspacesFind"), ("webhosting", "usersFind"), ("webhosting", "vhostsFind"),
    ("database", "databasesFind"), ("database", "usersFind"),
    ("domain", "domainsFind"), ("machine", "virtualMachinesFind"),
    ("account", "subaccountsFind"), ("account", "getOwnAccount"),
]

def call(base, key, service, method, params, account=None):
    body = dict(params, authToken=key)
    if account:
        body["ownerAccountId"] = account
    req = urllib.request.Request(f"{base}/{service}/v1/json/{method}", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "User-Agent": "kastellan-probe"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {"raw": "not json"}

class Anonymizer:
    def __init__(self):
        self.domains, self.locals, self.v4, self.v6 = {}, {}, {}, {}
    def domain(self, d):
        d = d.lower().rstrip(".")
        parts = d.split(".")
        if len(parts) < 2:
            return d
        root = ".".join(parts[-2:])
        idx = self.domains.setdefault(root, len(self.domains) + 1)
        sub = parts[:-2]
        return ".".join(sub + [f"example{'' if idx == 1 else idx}.com"])
    def text(self, s):
        def mail(m):
            loc = self.locals.setdefault(m.group(1), f"user{len(self.locals) + 1}")
            return f"{loc}@{self.domain(m.group(2))}"
        s = re.sub(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})", mail, s)
        def ip4(m):
            try:
                ipaddress.IPv4Address(m.group(0))
            except ValueError:
                return m.group(0)
            n = self.v4.setdefault(m.group(0), len(self.v4) + 10)
            return f"192.0.2.{n}"
        s = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", ip4, s)
        def ip6(m):
            try:
                ipaddress.IPv6Address(m.group(0))
            except ValueError:
                return m.group(0)
            n = self.v6.setdefault(m.group(0), len(self.v6) + 1)
            return f"2001:db8::{n:x}"
        s = re.sub(r"\b[0-9a-fA-F:]{2,}:[0-9a-fA-F:]+\b", ip6, s)
        s = re.sub(r"\b(?:[a-z0-9-]+\.)+(?:de|com|net|org|eu|cc|io|cloud)\b", lambda m: self.domain(m.group(0)), s)
        return s
    def walk(self, v):
        if isinstance(v, dict):
            return {k: ("***" if k in ("authToken", "password", "sshKey", "authInfo") else self.walk(x)) for k, x in v.items()}
        if isinstance(v, list):
            return [self.walk(x) for x in v]
        if isinstance(v, str):
            return self.text(v)
        return v

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out"); ap.add_argument("--account"); ap.add_argument("--base", default=BASE); ap.add_argument("--dump", action="store_true")
    ap.add_argument("--only", help="service/method")
    a = ap.parse_args()
    key = os.environ.get("HOSTINGDE_API_KEY")
    if not key:
        sys.exit("HOSTINGDE_API_KEY fehlt")
    anon = Anonymizer()
    for service, method in METHODS:
        if a.only and a.only != f"{service}/{method}":
            continue
        status, data = call(a.base, key, service, method, {"limit": 5, "page": 1}, a.account)
        st = data.get("status", "?")
        resp = data.get("response") or {}
        count = resp.get("totalEntries") if isinstance(resp, dict) else None
        errs = "; ".join(f"{e.get('code')}: {e.get('text')}" for e in data.get("errors", []) or [])
        print(f"{service}/{method}: HTTP {status}, status {st}, totalEntries {count}{' | ' + errs if errs else ''}")
        if a.dump:
            print(json.dumps(anon.walk(data), indent=2, ensure_ascii=False))
        if a.out:
            os.makedirs(a.out, exist_ok=True)
            name = re.sub(r"(?<!^)(?=[A-Z])", "-", method).lower()
            with open(os.path.join(a.out, f"{name}.json"), "w") as f:
                json.dump(anon.walk(data), f, indent=2, ensure_ascii=False)

if __name__ == "__main__":
    main()
