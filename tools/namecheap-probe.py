#!/usr/bin/env python3
"""Liest Inventar-Befehle der Namecheap-API und legt anonymisierte XML-Antworten als Fixtures ab.

Aufruf:  NAMECHEAP_API_USER=... NAMECHEAP_API_KEY=... NAMECHEAP_CLIENT_IP=... tools/namecheap-probe.py [--out DIR] [--dump] [--errors] [--max-domains N] [--domain D ...]
Optional: NAMECHEAP_USERNAME (Standard: API_USER), NAMECHEAP_SANDBOX=1 für api.sandbox.namecheap.com.

Nur lesende Befehle. Rate-Limit 50/min: das Skript wartet zwischen Aufrufen 1,5 Sekunden.
--errors ruft zusätzlich einmal mit fremder ClientIp auf. Namecheap prüft den Parameter nur auf das Format, die Antwort ist eine erste Seite mit 10 Domains (Pagination-Fixture).
"""
import argparse, ipaddress, os, re, sys, time, urllib.parse, urllib.request
import xml.etree.ElementTree as ET

NS = "http://api.namecheap.com/xml.response"
ET.register_namespace("", NS)

def endpoint():
    return "https://api.sandbox.namecheap.com/xml.response" if os.environ.get("NAMECHEAP_SANDBOX") == "1" else "https://api.namecheap.com/xml.response"

def call(auth, command, **params):
    form = dict(auth, Command=command, **params)
    req = urllib.request.Request(endpoint(), data=urllib.parse.urlencode(form).encode(), method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": "kastellan-probe"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")

def split(domain):
    # Registrierte Domains sind immer SLD.TLD, auch bei mehrteiligen TLDs wie co.uk.
    sld, _, tld = domain.partition(".")
    return sld, tld

class Anonymizer:
    SECRET_ATTRS = {"OwnerName", "User", "UserName", "ApiUser", "EmailAddress", "ForwardedTo", "FirstName", "LastName",
                    "Organization", "Phone", "Fax", "Address1", "Address2", "City", "PostalCode", "StateProvince", "ID"}
    DOMAIN_ATTRS = {"Name", "Domain", "DomainName", "HostName", "CommonName"}
    MONEY_ATTRS = {"AvailableBalance", "AccountBalance", "EarnedAmount", "WithdrawableAmount", "FundsRequiredForAutoRenew"}

    def __init__(self):
        self.domains, self.locals, self.v4, self.v6, self.names = {}, {}, {}, {}, {}

    def domain(self, d):
        parts = d.lower().rstrip(".").split(".")
        if len(parts) < 2: return d
        n = 3 if len(parts) >= 3 and parts[-2] in ("co", "com", "org", "net", "ac", "gov") and len(parts[-1]) == 2 else 2
        root = ".".join(parts[-n:])
        if re.fullmatch(r"example\d*\.com", root): return d  # schon anonymisiert
        idx = self.domains.setdefault(root, len(self.domains) + 1)
        return ".".join(parts[:-n] + [f"example{'' if idx == 1 else idx}.com"])

    def learn(self, domains):
        # Echte Domains aus getList, längste zuerst, damit Subdomains sauber ersetzt werden.
        self.known = sorted({d.lower() for d in domains}, key=len, reverse=True)
        for d in self.known: self.domain(d)

    def tokens(self, s):
        s = re.sub(r"(google-site-verification=)[\w-]+", lambda m: m.group(1) + "TOKEN" + str(self.counter("g", m.group(0))), s)
        s = re.sub(r"\bMS=ms\d+", lambda m: f"MS=ms{10000000 + self.counter('ms', m.group(0))}", s)
        s = re.sub(r"(\bp=)[A-Za-z0-9+/=]{20,}", r"\1MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAexample", s)
        s = re.sub(r"\b[\w-]+(\.mail\.protection\.)", r"example-com\1", s)
        return s

    def counter(self, kind, value):
        store = self.__dict__.setdefault("_c_" + kind, {})
        return store.setdefault(value, len(store) + 1)

    COMMON_LABELS = {"@", "*", "www", "mail", "webmail", "autodiscover", "autoconfig", "ftp", "smtp", "imap", "pop", "sip",
                     "lyncdiscover", "enterpriseregistration", "enterpriseenrollment", "_dmarc", "_domainkey", "default", "selector1", "selector2"}

    def host_name(self, name):
        def label(l):
            if l.lower() in self.COMMON_LABELS or re.fullmatch(r"example\d*|com", l): return l
            m = re.fullmatch(r"(_github-challenge-)(.+)", l)
            if m: return m.group(1) + f"org{self.counter('org', m.group(2))}"
            if l.startswith("_"): return l
            return f"host{self.counter('host', l.lower())}"
        name = self.text(name)
        return ".".join(label(l) for l in name.split("."))

    def text(self, s):
        if not s: return s
        s = self.tokens(s)
        for d in getattr(self, "known", []):
            s = re.sub(re.escape(d), lambda m: self.domain(m.group(0)), s, flags=re.I)
        s = re.sub(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})",
                   lambda m: f"{self.locals.setdefault(m.group(1), f'user{len(self.locals)+1}')}@{self.domain(m.group(2))}", s)
        def ip4(m):
            try: ipaddress.IPv4Address(m.group(0))
            except ValueError: return m.group(0)
            return f"192.0.2.{self.v4.setdefault(m.group(0), len(self.v4)+10)}"
        s = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", ip4, s)
        def ip6(m):
            try: ipaddress.IPv6Address(m.group(0))
            except ValueError: return m.group(0)
            return f"2001:db8::{self.v6.setdefault(m.group(0), len(self.v6)+10):x}"
        s = re.sub(r"\b[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{0,4}){2,7}\b", ip6, s)
        s = re.sub(r"(?<![\w.=-])(?:[a-z0-9_-]+\.)+[a-z]{2,}(?![\w-])",
                   lambda m: m.group(0) if "namecheap" in m.group(0) or "registrar-servers" in m.group(0) else self.domain(m.group(0)), s, flags=re.I)
        return s

    def walk(self, el):
        is_host = el.tag.split("}")[-1] == "host"
        if is_host and el.get("Name"):
            el.set("Name", self.host_name(el.get("Name")))
            if el.get("Type") == "TXT" and el.get("Name", "").startswith("_") and re.fullmatch(r"[0-9a-f]{6,}", el.get("Address", "")):
                el.set("Address", "0" * len(el.get("Address")))
        for k, v in list(el.attrib.items()):
            if is_host and k == "Name":
                continue
            if k in self.SECRET_ATTRS:
                el.set(k, self.names.setdefault(v, f"anon{len(self.names)+1}") if v else v)
            elif k in self.DOMAIN_ATTRS and v and "." in v:
                el.set(k, self.domain(v))
            elif k in self.MONEY_ATTRS:
                el.set(k, "0.00")
            else:
                el.set(k, self.text(v))
        if el.text and el.text.strip():
            local = el.tag.split("}")[-1]
            el.text = self.names.setdefault(el.text, f"anon{len(self.names)+1}") if local in self.SECRET_ATTRS else self.text(el.text)
        for child in el: self.walk(child)
        return el

def count(root, local):
    return sum(1 for e in root.iter() if e.tag.split("}")[-1] == local)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out"); ap.add_argument("--dump", action="store_true"); ap.add_argument("--errors", action="store_true")
    ap.add_argument("--max-domains", type=int, default=4)
    ap.add_argument("--domain", action="append", help="bestimmte Domain abfragen, mehrfach möglich")
    ap.add_argument("--rescrub", metavar="DIR", help="vorhandene Fixtures ohne API-Aufruf erneut anonymisieren")
    a = ap.parse_args()
    if a.rescrub:
        anon = Anonymizer()
        for fn in sorted(os.listdir(a.rescrub)):
            if not fn.endswith(".xml"): continue
            path = os.path.join(a.rescrub, fn)
            root = anon.walk(ET.parse(path).getroot())
            with open(path, "w") as f:
                f.write('<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(root, encoding="unicode") + "\n")
        return
    user, key, ip = (os.environ.get(k) for k in ("NAMECHEAP_API_USER", "NAMECHEAP_API_KEY", "NAMECHEAP_CLIENT_IP"))
    if not (user and key and ip): sys.exit("NAMECHEAP_API_USER, NAMECHEAP_API_KEY und NAMECHEAP_CLIENT_IP setzen")
    auth = {"ApiUser": user, "ApiKey": key, "UserName": os.environ.get("NAMECHEAP_USERNAME", user), "ClientIp": ip}
    anon = Anonymizer()
    if a.out: os.makedirs(a.out, exist_ok=True)

    def run(name, command, summary=None, auth_override=None, **params):
        status, body = call(auth_override or auth, command, **params); time.sleep(1.5)
        try:
            root = ET.fromstring(body)
        except ET.ParseError:
            print(f"{name}: HTTP {status}, keine XML-Antwort"); return None
        api_status = root.get("Status")
        errors = [f"{e.get('Number')}: {anon.text(e.text or '')}" for e in root.iter(f"{{{NS}}}Error")]
        info = f", {summary(root)}" if summary and api_status == "OK" else ""
        print(f"{name}: HTTP {status}, {api_status}{info}" + (f", Fehler {errors}" if errors else ""))
        clean = anon.walk(ET.fromstring(body))
        xml = ET.tostring(clean, encoding="unicode")
        if a.dump: print(xml)
        if a.out:
            with open(os.path.join(a.out, re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") + ".xml"), "w") as f:
                f.write('<?xml version="1.0" encoding="utf-8"?>\n' + xml + "\n")
        return root if api_status == "OK" else None

    # Domainliste zuerst ungespeichert holen: die echten Namen braucht die Anonymisierung, bevor irgendetwas abgelegt wird.
    status, body = call(auth, "namecheap.domains.getList", PageSize="100"); time.sleep(1.5)
    try:
        raw = [d.attrib for d in ET.fromstring(body).iter(f"{{{NS}}}Domain")]
    except ET.ParseError:
        sys.exit(f"domains.getList: HTTP {status}, keine XML-Antwort")
    anon.learn([d["Name"] for d in raw if d.get("Name")])

    def created(d):
        m, dd, y = (d.get("Created") or "01/01/9999").split("/")
        return (y, m, dd)
    if a.domain:
        domains = a.domain
    else:
        # Eine Domain mit fremdem DNS und die ältesten mit Namecheap-DNS: dort stehen am ehesten Records.
        foreign = [d["Name"] for d in raw if d.get("IsOurDNS") == "false"][:1]
        own = [d["Name"] for d in sorted(raw, key=created) if d.get("IsOurDNS") == "true"]
        domains = foreign + own[: max(a.max_domains - len(foreign), 0)]

    run("users.getBalances", "namecheap.users.getBalances")
    run("domains.getList", "namecheap.domains.getList", lambda r: f"{count(r, 'Domain')} Domains", PageSize="100")

    for d in domains:
        sld, tld = split(d)
        label = anon.domain(d)
        run(f"domains.getInfo {label}", "namecheap.domains.getInfo", DomainName=d)
        run(f"domains.getRegistrarLock {label}", "namecheap.domains.getRegistrarLock", DomainName=d)
        run(f"domains.dns.getList {label}", "namecheap.domains.dns.getList", SLD=sld, TLD=tld)
        run(f"domains.dns.getHosts {label}", "namecheap.domains.dns.getHosts", lambda r: f"{count(r, 'host')} Records", SLD=sld, TLD=tld)
        run(f"domains.dns.getEmailForwarding {label}", "namecheap.domains.dns.getEmailForwarding", DomainName=d)

    run("ssl.getList", "namecheap.ssl.getList", lambda r: f"{count(r, 'SSL')} Zertifikate", PageSize="100")

    if a.errors:
        run("domains.getList foreign-client-ip page1", "namecheap.domains.getList", auth_override=dict(auth, ClientIp="192.0.2.1"), PageSize="10")

if __name__ == "__main__":
    main()
