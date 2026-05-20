#!/usr/bin/env bash
# Tear down the GCP VM created by provision.sh, plus any stale firewall rules
# left behind by older versions of the script.
#
# Usage:
#   bash decommission.sh           # interactive — prompts before deleting
#   bash decommission.sh --yes     # skip the confirmation prompt
#
# Reads the same env vars provision.sh uses, so a customised INSTANCE_NAME /
# ZONE stays in sync if you set both via your shell:
#   INSTANCE_NAME (default: exam-vm)
#   ZONE          (default: us-central1-a)

set -euo pipefail

INSTANCE_NAME="${INSTANCE_NAME:-exam-vm}"
ZONE="${ZONE:-us-central1-a}"

log() { echo; echo "=== $* ==="; }

# ── Prerequisites ──────────────────────────────────────────────────────────────
if ! command -v gcloud &>/dev/null; then
    echo "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
    exit 1
fi

PROJECT=$(gcloud config get-value project 2>/dev/null || true)
if [[ -z "$PROJECT" ]]; then
    echo "No GCP project set. Run: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    echo "Not authenticated. Run: gcloud auth login"
    exit 1
fi

# ── Discover what actually exists ─────────────────────────────────────────────
VM_EXISTS=false
VM_IP=""
if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --quiet &>/dev/null; then
    VM_EXISTS=true
    VM_IP=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "?")
fi

LEGACY_RULES=()
for rule in allow-exam-grafana allow-exam-prometheus; do
    if gcloud compute firewall-rules describe "$rule" --quiet &>/dev/null; then
        LEGACY_RULES+=("$rule")
    fi
done

if ! $VM_EXISTS && [[ ${#LEGACY_RULES[@]} -eq 0 ]]; then
    echo "Nothing to clean up in project $PROJECT (zone $ZONE)."
    exit 0
fi

# ── Show plan + confirm ───────────────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────┐"
echo "│        GCP resources marked for deletion        │"
echo "└─────────────────────────────────────────────────┘"
echo ""
echo "  Project : $PROJECT"
if $VM_EXISTS; then
    echo "  VM      : $INSTANCE_NAME  ($VM_IP)"
    echo "  Zone    : $ZONE"
fi
if [[ ${#LEGACY_RULES[@]} -gt 0 ]]; then
    echo "  Legacy firewall rules: ${LEGACY_RULES[*]}"
fi
echo ""

if [[ "${1:-}" != "--yes" ]]; then
    read -rp "Type 'yes' to delete: " _confirm < /dev/tty
    if [[ "$_confirm" != "yes" ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

# ── Delete ─────────────────────────────────────────────────────────────────────
if $VM_EXISTS; then
    log "Deleting VM"
    # Boot disk is auto-deleted by default (auto_delete=true at creation), so
    # no separate disk cleanup needed.
    gcloud compute instances delete "$INSTANCE_NAME" --zone="$ZONE" --quiet
fi

if [[ ${#LEGACY_RULES[@]} -gt 0 ]]; then
    log "Removing legacy firewall rules"
    for rule in "${LEGACY_RULES[@]}"; do
        gcloud compute firewall-rules delete "$rule" --quiet
        echo "  Removed: $rule"
    done
fi

echo ""
echo "┌──────────────────────────────────────────────────────┐"
echo "│  DECOMMISSIONED                                      │"
echo "└──────────────────────────────────────────────────────┘"
if [[ -n "$VM_IP" && "$VM_IP" != "?" ]]; then
    echo ""
    echo "  Heads-up: if a DNS A record pointed at $VM_IP,"
    echo "  it still does. Update it in cPanel (or wherever) before"
    echo "  the next provision so certbot doesn't validate against a dead IP."
fi
