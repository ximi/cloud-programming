#!/usr/bin/env bash
# bootstrap.sh — single-command entry point for the exam deployment.
# Downloads the full deployment repository as a tarball and runs setup_exam.sh.
#
# Usage (on a fresh Ubuntu/Debian VM):
#   curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/bootstrap.sh | sudo bash
#
# If invoking over SSH, allocate a TTY so the interactive prompts work:
#   ssh -t user@vm 'curl -fsSL .../bootstrap.sh | sudo bash'

set -euo pipefail

REPO_TARBALL="${REPO_TARBALL:-https://github.com/ximi/cloud-programming/archive/refs/heads/master.tar.gz}"
WORK_DIR="${WORK_DIR:-/tmp/cloud-programming-deploy}"

if [[ $EUID -ne 0 ]]; then
    echo "bootstrap.sh must run as root."
    echo "Try: curl -fsSL <url>/bootstrap.sh | sudo bash"
    exit 1
fi

echo "==> Downloading deployment repository..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
curl -fsSL "$REPO_TARBALL" | tar -xz -C "$WORK_DIR" --strip-components=1
chmod +x "$WORK_DIR"/*.sh

echo "==> Running setup_exam.sh..."
cd "$WORK_DIR"
exec bash ./setup_exam.sh
