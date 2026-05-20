#!/usr/bin/env bash
# Application deployment.
#
# Default behaviour: fetch the latest webapp.py from a URL and install it at
# /opt/webapp.py, then restart the systemd unit. The default URL points at
# this repo's master branch, but it's a single env var to redirect to a real
# app repo when you move the application out.
#
# Usage:
#   sudo bash deploy_app.sh                            # pull from default URL
#   sudo WEBAPP_URL=https://… bash deploy_app.sh       # pull from a different URL
#   sudo WEBAPP_FILE=./webapp.py bash deploy_app.sh    # install a local file
#                                                       (useful for testing
#                                                       before you push)
#
# Prerequisite: setup.sh has run on this VM once, so webapp.service and
# /etc/webapp.env exist.

set -euo pipefail

WEBAPP_URL="${WEBAPP_URL:-https://raw.githubusercontent.com/ximi/cloud-programming/master/webapp.py}"
WEBAPP_FILE="${WEBAPP_FILE:-}"

if [[ $EUID -ne 0 ]]; then
    echo "deploy_app.sh must run as root. Try: sudo bash deploy_app.sh"
    exit 1
fi

if [[ ! -f /etc/systemd/system/webapp.service ]]; then
    echo "ERROR: /etc/systemd/system/webapp.service not found. Run setup.sh first."
    exit 1
fi

id appuser &>/dev/null || useradd -r -s /usr/sbin/nologin appuser

# Resolve source: explicit local file overrides; otherwise download.
TMP_SRC=""
if [[ -n "$WEBAPP_FILE" ]]; then
    [[ -f "$WEBAPP_FILE" ]] || { echo "ERROR: WEBAPP_FILE=$WEBAPP_FILE not found"; exit 1; }
    SRC="$WEBAPP_FILE"
    SRC_LABEL="$WEBAPP_FILE (local)"
else
    TMP_SRC=$(mktemp)
    trap '[[ -n "$TMP_SRC" ]] && rm -f "$TMP_SRC"' EXIT
    echo "  Fetching $WEBAPP_URL"
    curl -fsSL --max-time 30 "$WEBAPP_URL" -o "$TMP_SRC"
    SRC="$TMP_SRC"
    SRC_LABEL="$WEBAPP_URL"
fi

# Light sanity check — must be non-empty and look like Python.
if [[ ! -s "$SRC" ]] || ! head -n 5 "$SRC" | grep -qi 'python'; then
    echo "ERROR: $SRC_LABEL doesn't look like a Python script (empty or no python in first 5 lines)."
    exit 1
fi

install -m 644 -o appuser -g appuser "$SRC" /opt/webapp.py
echo "  Installed $SRC_LABEL -> /opt/webapp.py"

systemctl daemon-reload
systemctl restart webapp

sleep 2
if systemctl is-active --quiet webapp; then
    echo "  webapp.service is active"
else
    echo "ERROR: webapp service failed to start. Recent logs:"
    journalctl -u webapp -n 30 --no-pager || true
    exit 1
fi

echo "App deployment complete."
