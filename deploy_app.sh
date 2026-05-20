#!/usr/bin/env bash
# Application deployment process.
# Installs/updates webapp.py at /opt/webapp.py and restarts the systemd service.
# Idempotent — safe to run on initial deploy or for updates.
#
# Usage: sudo bash deploy_app.sh
# Prerequisite: the infrastructure (webapp.service, /etc/webapp.env, Vault) must
# have been provisioned first via setup_exam.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "deploy_app.sh must be run as root. Try: sudo bash deploy_app.sh"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/webapp.py" ]]; then
    echo "ERROR: webapp.py not found at $SCRIPT_DIR/webapp.py"
    exit 1
fi

# Ensure the unprivileged app user exists (idempotent).
id appuser &>/dev/null || useradd -r -s /usr/sbin/nologin appuser

# Install the new application code.
install -m 644 -o appuser -g appuser "$SCRIPT_DIR/webapp.py" /opt/webapp.py
echo "  Installed $SCRIPT_DIR/webapp.py -> /opt/webapp.py"

# Reload systemd in case the unit file was newly written by setup_exam.sh, then
# (re)start the service. `restart` doubles as `start` when the unit isn't running.
systemctl daemon-reload
systemctl restart webapp

# Give it a moment, then verify.
sleep 2
if systemctl is-active --quiet webapp; then
    echo "  webapp.service is active"
else
    echo "ERROR: webapp service failed to start. Recent logs:"
    journalctl -u webapp -n 30 --no-pager || true
    exit 1
fi

echo "App deployment complete."
