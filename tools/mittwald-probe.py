#!/usr/bin/env python3
"""Liest Inventar-Endpunkte der Mittwald mStudio API und legt anonymisierte Antworten als Fixtures ab.

Aufruf:  MITTWALD_API_TOKEN=... tools/mittwald-probe.py [--out DIR] [--project UUID] [--dump]
"""
import argparse, ipaddress, json, os, re, sys, urllib.request

BASE = "https://api.mittwald.de/v2"

def call(token, path):
    req = urllib.request.Request(BASE + path, headers={"Authorization": f"Bearer {token}", "Accept": "application/json", "User-Agent": "kastellan-probe"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode() or "null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {"raw": "not json"}

class Anonymizer:
    def __init__(self):
        self.domains, self.locals, self.v4, self.v6, self.uuids = {}, {}, {}, {}, {}
    def domain(self, d):
        parts = d.lower().rstrip(".").split(".")
        if len(parts) < 2: return d
        root = ".".join(parts[-2:])
        idx = self.domains.setdefault(root, len(self.domains) + 1)
        return ".".join(parts[:-2] + [f"example{'' if idx == 1 else idx}.com"])
    def text(self, s):
        s = re.sub(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})", lambda m: f"{self.locals.setdefault(m.group(1), f'user{len(self.locals)+1}')}@{self.domain(m.group(2))}", s)
        def ip4(m):
            try: ipaddress.IPv4Address(m.group(0))
            except ValueError: return m.group(0)
            return f"192.0.2.{self.v4.setdefault(m.group(0), len(self.v4)+10)}"
        s = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", ip4, s)
        s = re.sub(r"\b(?:[a-z0-9-]+\.)+(?:de|com|net|org|eu|cc|io|cloud|info|host)\b", lambda m: self.domain(m.group(0)), s)
        return s
    def walk(self, v):
        if isinstance(v, dict):
            return {k: ("***" if k in ("password", "authCode", "privateKey", "key") else self.walk(x)) for k, x in v.items()}
        if isinstance(v, list): return [self.walk(x) for x in v]
        if isinstance(v, str): return self.text(v)
        return v

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out"); ap.add_argument("--project"); ap.add_argument("--dump", action="store_true")
    a = ap.parse_args()
    token = os.environ.get("MITTWALD_API_TOKEN")
    if not token: sys.exit("MITTWALD_API_TOKEN fehlt")
    anon = Anonymizer()
    status, projects = call(token, "/projects?limit=50")
    print(f"/projects: HTTP {status}, {len(projects) if isinstance(projects, list) else projects}")
    ids = [a.project] if a.project else [p["id"] for p in projects] if isinstance(projects, list) else []
    paths = ["/servers", "/customers", "/domains", "/ingresses", "/certificates", "/users/self/api-tokens"]
    for pid in ids:
        paths += [f"/projects/{pid}", f"/projects/{pid}/dns-zones", f"/projects/{pid}/mail-addresses", f"/projects/{pid}/mysql-databases",
                  f"/projects/{pid}/redis-databases", f"/projects/{pid}/ssh-users", f"/projects/{pid}/sftp-users", f"/projects/{pid}/cronjobs",
                  f"/projects/{pid}/app-installations", f"/projects/{pid}/memberships", f"/projects/{pid}/invites"]
    for path in paths:
        status, data = call(token, path)
        n = len(data) if isinstance(data, list) else "-"
        print(f"{path}: HTTP {status}, {n}")
        if a.dump: print(json.dumps(anon.walk(data), indent=2, ensure_ascii=False))
        if a.out:
            os.makedirs(a.out, exist_ok=True)
            name = re.sub(r"[^a-z0-9]+", "-", path.strip("/").lower()).strip("-")
            with open(os.path.join(a.out, f"{name}.json"), "w") as f:
                json.dump(anon.walk(data), f, indent=2, ensure_ascii=False)

if __name__ == "__main__":
    main()
