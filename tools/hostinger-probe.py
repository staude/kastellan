#!/usr/bin/env python3
"""Liest Inventar-Endpunkte der Hostinger-API und legt anonymisierte Antworten als Fixtures ab.

Aufruf:  HOSTINGER_API_TOKEN=... tools/hostinger-probe.py [--out DIR] [--dump]
Rate-Limit 90/min: das Skript wartet zwischen Aufrufen eine Sekunde.
"""
import argparse, ipaddress, json, os, re, sys, time, urllib.request

BASE = "https://developers.hostinger.com"

def call(token, path):
    req = urllib.request.Request(BASE + path, headers={"Authorization": f"Bearer {token}", "Accept": "application/json", "Content-Type": "application/json", "User-Agent": "kastellan-probe"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode() or "null")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read().decode())
        except Exception: return e.code, {"raw": "not json"}

class Anonymizer:
    def __init__(self): self.domains, self.locals, self.v4 = {}, {}, {}
    def domain(self, d):
        parts = d.lower().rstrip(".").split(".")
        if len(parts) < 2: return d
        root = ".".join(parts[-2:]); idx = self.domains.setdefault(root, len(self.domains) + 1)
        return ".".join(parts[:-2] + [f"example{'' if idx == 1 else idx}.com"])
    def text(self, s):
        s = re.sub(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})", lambda m: f"{self.locals.setdefault(m.group(1), f'user{len(self.locals)+1}')}@{self.domain(m.group(2))}", s)
        def ip4(m):
            try: ipaddress.IPv4Address(m.group(0))
            except ValueError: return m.group(0)
            return f"192.0.2.{self.v4.setdefault(m.group(0), len(self.v4)+10)}"
        s = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", ip4, s)
        s = re.sub(r"\b(?:[a-z0-9-]+\.)+(?:de|com|net|org|eu|cc|io|cloud|info|host|online|site|shop|xyz)\b", lambda m: self.domain(m.group(0)), s)
        return s
    def walk(self, v):
        if isinstance(v, dict): return {k: ("***" if k in ("password", "key", "auth_code", "token") else self.walk(x)) for k, x in v.items()}
        if isinstance(v, list): return [self.walk(x) for x in v]
        if isinstance(v, str): return self.text(v)
        return v

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out"); ap.add_argument("--dump", action="store_true"); a = ap.parse_args()
    token = os.environ.get("HOSTINGER_API_TOKEN")
    if not token: sys.exit("HOSTINGER_API_TOKEN fehlt")
    anon = Anonymizer()
    paths = ["/api/domains/v1/portfolio", "/api/billing/v1/subscriptions", "/api/vps/v1/virtual-machines", "/api/vps/v1/firewall", "/api/vps/v1/public-keys",
             "/api/mail/v1/orders", "/api/hosting/v1/websites", "/api/hosting/v1/orders"]
    extra = []
    for path in paths:
        status, data = call(token, path); time.sleep(1)
        n = len(data) if isinstance(data, list) else len(data.get("data", [])) if isinstance(data, dict) and "data" in data else "-"
        print(f"{path}: HTTP {status}, {n}")
        if a.dump: print(json.dumps(anon.walk(data), indent=2, ensure_ascii=False))
        if a.out:
            os.makedirs(a.out, exist_ok=True)
            with open(os.path.join(a.out, re.sub(r"[^a-z0-9]+", "-", path.strip("/").lower()).strip("-") + ".json"), "w") as f:
                json.dump(anon.walk(data), f, indent=2, ensure_ascii=False)
        if path.endswith("/portfolio") and isinstance(data, list):
            extra += [f"/api/dns/v1/zones/{d['domain']}" for d in data[:3] if d.get("domain")]
        if path.endswith("/websites") and isinstance(data, dict):
            for w in data.get("data", [])[:2]:
                u, d = w.get("username"), w.get("domain")
                if u and d: extra += [f"/api/hosting/v1/accounts/{u}/websites/{d}/subdomains", f"/api/hosting/v1/accounts/{u}/databases", f"/api/hosting/v1/accounts/{u}/cron-jobs"]
        if path.endswith("/mail/v1/orders") and isinstance(data, dict):
            for o in data.get("data", [])[:2]:
                extra += [f"/api/mail/v1/orders/{o['id']}/mailboxes", f"/api/mail/v1/orders/{o['id']}/forwarders", f"/api/mail/v1/orders/{o['id']}/aliases", f"/api/mail/v1/orders/{o['id']}/autoreplies"]
    for path in extra:
        status, data = call(token, path); time.sleep(1)
        print(f"{path}: HTTP {status}")
        if a.dump: print(json.dumps(anon.walk(data), indent=2, ensure_ascii=False))
        if a.out:
            with open(os.path.join(a.out, re.sub(r"[^a-z0-9]+", "-", anon.text(path).strip("/").lower()).strip("-") + ".json"), "w") as f:
                json.dump(anon.walk(data), f, indent=2, ensure_ascii=False)

if __name__ == "__main__":
    main()
