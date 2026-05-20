#!/usr/bin/env python3
"""
certbot DNS-01 hook for cPanel.

certbot calls this script twice per certificate request: once as `auth` to
create the _acme-challenge TXT record, and once as `cleanup` to remove it.
The cPanel credentials come from Vault (secret/cpanel), same as ddns-update.py.

Usage (certbot invokes these via --manual-auth-hook / --manual-cleanup-hook):
  cpanel-dns-hook.py auth
  cpanel-dns-hook.py cleanup

Environment (also loaded from /etc/cpanel-dns-hook.env if present, so the
Vault token doesn't have to live on certbot's command line — and therefore
not in /etc/letsencrypt/renewal/<domain>.conf either):
  VAULT_ADDR, VAULT_TOKEN    — Vault location + a token with read on secret/cpanel
  CERTBOT_DOMAIN             — set by certbot (e.g. "exam.maximilianzimmer.com")
  CERTBOT_VALIDATION         — set by certbot (the TXT value to publish)
  CPANEL_ZONE (optional)     — DNS zone to edit. Default: last two labels.
"""

import base64
import json
import os
import sys
import time
import urllib.parse
import urllib.request

ENV_FILE = "/etc/cpanel-dns-hook.env"
if os.path.exists(ENV_FILE):
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k, v)

VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://127.0.0.1:8200")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "")


def vault_get(path):
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())["data"]


def cpanel_api(host, user, password, params):
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    url = f"{host}/json-api/cpanel?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def main():
    if not VAULT_TOKEN:
        sys.exit("ERROR: VAULT_TOKEN not set (no env, no /etc/cpanel-dns-hook.env)")

    action = sys.argv[1] if len(sys.argv) > 1 else ""
    domain = os.environ.get("CERTBOT_DOMAIN", "").rstrip(".")
    validation = os.environ.get("CERTBOT_VALIDATION", "")

    if not domain:
        sys.exit("ERROR: CERTBOT_DOMAIN not set")
    if action not in ("auth", "cleanup"):
        sys.exit(f"ERROR: unknown action '{action}' (expected 'auth' or 'cleanup')")

    zone = os.environ.get("CPANEL_ZONE") or ".".join(domain.split(".")[-2:])
    txt_name = f"_acme-challenge.{domain}."

    creds = vault_get("secret/cpanel")
    host = creds["host"]
    user = creds["username"]
    password = creds["password"]

    if action == "auth":
        cpanel_api(host, user, password, {
            "cpanel_jsonapi_module": "ZoneEdit",
            "cpanel_jsonapi_func": "add_zone_record",
            "domain": zone,
            "type": "TXT",
            "name": txt_name,
            "txtdata": validation,
            "ttl": "60",
        })
        print(f"  Added TXT {txt_name}", flush=True)
        # cPanel writes to the authoritative zone fast, but the LE validator
        # queries the public DNS hierarchy. 30s covers typical propagation.
        # Bump this if you see "Incorrect TXT record" failures.
        time.sleep(30)
    else:  # cleanup
        result = cpanel_api(host, user, password, {
            "cpanel_jsonapi_module": "ZoneEdit",
            "cpanel_jsonapi_func": "fetchzone_records",
            "domain": zone,
            "type": "TXT",
            "name": txt_name,
        })
        for rec in result.get("cpanelresult", {}).get("data", []):
            if rec.get("txtdata", "").strip('"') == validation:
                line = rec.get("line", "")
                if line:
                    cpanel_api(host, user, password, {
                        "cpanel_jsonapi_module": "ZoneEdit",
                        "cpanel_jsonapi_func": "remove_zone_record",
                        "domain": zone,
                        "line": line,
                    })
                    print(f"  Removed TXT line {line}", flush=True)


if __name__ == "__main__":
    main()
