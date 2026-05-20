#!/usr/bin/env python3
"""
Dynamic DNS updater for exam.maximilianzimmer.com via cPanel API.
Reads cPanel credentials from Vault at runtime — no hardcoded secrets.
"""

import json
import os
import sys
import urllib.request
import urllib.parse
import urllib.error
import base64

VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://127.0.0.1:8200")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "")
SUBDOMAIN = "exam.maximilianzimmer.com"
ZONE = "maximilianzimmer.com"


def get_public_ip():
    for url in ["https://api4.my-ip.io/ip", "https://ifconfig.me/ip", "https://ipinfo.io/ip"]:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                return r.read().decode().strip()
        except Exception:
            continue
    raise RuntimeError("Could not determine public IP")


def vault_get(path):
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN}
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())["data"]


def cpanel_api(host, username, password, params):
    auth = base64.b64encode(f"{username}:{password}".encode()).decode()
    url = f"{host}/json-api/cpanel?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def get_current_dns_ip(host, username, password):
    result = cpanel_api(host, username, password, {
        "cpanel_jsonapi_module": "ZoneEdit",
        "cpanel_jsonapi_func": "fetchzone_records",
        "domain": ZONE,
        "type": "A",
        "name": SUBDOMAIN + ".",
    })
    records = result.get("cpanelresult", {}).get("data", [])
    if records:
        return records[0].get("address", ""), records[0].get("line", "")
    return "", ""


def update_dns(host, username, password, line, new_ip):
    result = cpanel_api(host, username, password, {
        "cpanel_jsonapi_module": "ZoneEdit",
        "cpanel_jsonapi_func": "edit_zone_record",
        "domain": ZONE,
        "line": line,
        "type": "A",
        "name": SUBDOMAIN + ".",
        "address": new_ip,
        "ttl": "300",
    })
    return result


def add_dns(host, username, password, new_ip):
    result = cpanel_api(host, username, password, {
        "cpanel_jsonapi_module": "ZoneEdit",
        "cpanel_jsonapi_func": "add_zone_record",
        "domain": ZONE,
        "type": "A",
        "name": SUBDOMAIN + ".",
        "address": new_ip,
        "ttl": "300",
    })
    return result


def main():
    if not VAULT_TOKEN:
        print("ERROR: VAULT_TOKEN not set", file=sys.stderr)
        sys.exit(1)

    creds = vault_get("secret/cpanel")
    cp_host = creds["host"]
    cp_user = creds["username"]
    cp_pass = creds["password"]

    # Target IP precedence: explicit CLI arg > public-IP echo. The Tailscale
    # case passes the Tailscale 100.x.x.x address as argv[1] — that's the
    # routable VM address on the Tailscale net, not the home router's WAN.
    if len(sys.argv) > 1 and sys.argv[1]:
        target_ip = sys.argv[1]
    else:
        target_ip = get_public_ip()
        if not target_ip:
            print("ERROR: could not determine an IP and none was provided", file=sys.stderr)
            sys.exit(1)

    current_ip, line = get_current_dns_ip(cp_host, cp_user, cp_pass)

    if current_ip == target_ip:
        print(f"DNS already correct: {SUBDOMAIN} -> {target_ip}")
        return

    if line:
        update_dns(cp_host, cp_user, cp_pass, line, target_ip)
        print(f"Updated {SUBDOMAIN}: {current_ip} -> {target_ip}")
    else:
        add_dns(cp_host, cp_user, cp_pass, target_ip)
        print(f"Created {SUBDOMAIN} -> {target_ip}")


if __name__ == "__main__":
    main()
