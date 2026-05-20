#!/usr/bin/env bash
# Provision a free-tier GCP VM and deploy the full stack onto it.
#
# Runs from ANY computer with `gcloud` installed and authenticated. The VM
# itself pulls all deployment scripts from GitHub via bootstrap.sh, so this
# script needs no local files.
#
# Usage (from a local clone):
#   bash provision.sh
#
# Usage (from anywhere, no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/provision.sh | bash
#
# Prerequisites (one-time per laptop):
#   gcloud auth login
#   gcloud config set project YOUR_PROJECT_ID

set -euo pipefail

INSTANCE_NAME="${INSTANCE_NAME:-exam-vm}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
DOMAIN="${DOMAIN:-exam.maximilianzimmer.com}"
DNS_ZONE="${DNS_ZONE:-maximilianzimmer.com}"
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/ximi/cloud-programming/master}"

log() { echo; echo "=== $* ==="; }

# ── Failure handler ───────────────────────────────────────────────────────────
# If provisioning fails after the VM is created, the VM keeps running (and
# accruing cost). Warn the user with the exact delete command so they don't
# have to dig it up. We deliberately do NOT auto-delete — that would destroy
# debugging state if the user wants to SSH in and investigate.
cleanup_on_failure() {
    local exit_code=$?
    [[ $exit_code -eq 0 ]] && return
    gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --quiet &>/dev/null || return

    local ip
    ip=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" \
        --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "?")

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    printf "║  PROVISIONING FAILED (exit %-3s)                                       ║\n" "$exit_code"
    echo "╠══════════════════════════════════════════════════════════════════════╣"
    printf "║  VM %s (%s) is still running and will accrue cost.\n" "$INSTANCE_NAME" "$ip"
    echo "║"
    printf "║  Delete:  gcloud compute instances delete %s --zone=%s --quiet\n" "$INSTANCE_NAME" "$ZONE"
    printf "║  Debug:   gcloud compute ssh %s --zone=%s\n" "$INSTANCE_NAME" "$ZONE"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
}
trap cleanup_on_failure EXIT

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

# ── Collect credentials ────────────────────────────────────────────────────────
# Read from /dev/tty so this script works when invoked via `curl ... | bash`
# (where stdin is the pipe, not the terminal).
echo ""
echo "┌─────────────────────────────────────────────────┐"
echo "│         GCP Exam Environment Provisioner        │"
echo "└─────────────────────────────────────────────────┘"
echo ""
echo "  Project : $PROJECT"
echo "  Zone    : $ZONE"
echo "  Machine : $MACHINE_TYPE  (always-free tier)"
echo ""

while true; do
    read -rsp "  OpenWeatherMap API key: " WEATHER_API_KEY < /dev/tty; echo
    [[ -n "$WEATHER_API_KEY" ]] && break
    echo "  API key cannot be empty."
done

echo ""
read -rp "  Configure custom domain ($DOMAIN)? [y/N]: " _domain_answer < /dev/tty
USE_DOMAIN=false
# Portable case-insensitive match — macOS still ships bash 3.2, where the
# bash-4+ `${var,,}` lowercase expansion is a syntax error.
[[ "$_domain_answer" =~ ^[yY]([eE][sS])?$ ]] && USE_DOMAIN=true

CPANEL_HOST="" CPANEL_USER="" CPANEL_PASS="" CERTBOT_EMAIL=""
if $USE_DOMAIN; then
    echo ""
    read -rp  "  cPanel host     : " CPANEL_HOST    < /dev/tty; echo
    read -rp  "  cPanel username : " CPANEL_USER    < /dev/tty; echo
    read -rsp "  cPanel password : " CPANEL_PASS    < /dev/tty; echo
    read -rp  "  Email (certbot) : " CERTBOT_EMAIL  < /dev/tty; echo
fi

# ── [1/4] Create VM ────────────────────────────────────────────────────────────
log "[1/4] Creating VM"

if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --quiet &>/dev/null; then
    echo "  Instance already exists, reusing"
else
    gcloud compute instances create "$INSTANCE_NAME" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --image-family="$IMAGE_FAMILY" \
        --image-project="$IMAGE_PROJECT" \
        --boot-disk-size=20GB \
        --boot-disk-type=pd-standard \
        --tags=http-server,https-server,exam-vm
    echo "  Created: $INSTANCE_NAME"
fi

VM_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

if [[ -z "$VM_IP" ]]; then
    echo "ERROR: VM exists but has no external IP attached. Inspect with:"
    echo "  gcloud compute instances describe $INSTANCE_NAME --zone=$ZONE"
    exit 1
fi
echo "  Public IP: $VM_IP"

# ── [2/4] Firewall ─────────────────────────────────────────────────────────────
log "[2/4] Firewall"

# Clean up any legacy per-service rules from older provision.sh runs (Grafana
# and Prometheus go through Nginx on :443, so they have no business being on
# their own ports).
for stale_rule in allow-exam-grafana allow-exam-prometheus; do
    if gcloud compute firewall-rules describe "$stale_rule" --quiet &>/dev/null; then
        gcloud compute firewall-rules delete "$stale_rule" --quiet
        echo "  Removed legacy rule: $stale_rule"
    fi
done

# Ensure :80 and :443 are actually open. The default-allow-http/https rules
# ship with auto-mode VPCs but are NOT guaranteed to exist on older projects,
# custom networks, or projects where org policy stripped them. We check for
# any rule already covering tag+port first; only create our own if nothing
# else matches.
for rule_spec in "allow-app-http:80:http-server" "allow-app-https:443:https-server"; do
    IFS=':' read -r rule_name port tag <<< "$rule_spec"
    existing=$(gcloud compute firewall-rules list \
        --filter="targetTags:${tag} AND allowed.ports:${port}" \
        --format="value(name)" 2>/dev/null | head -1)
    if [[ -n "$existing" ]]; then
        echo "  tcp:${port} already allowed for tag ${tag} (rule: ${existing})"
    else
        gcloud compute firewall-rules create "$rule_name" \
            --allow="tcp:${port}" \
            --target-tags="$tag" \
            --source-ranges=0.0.0.0/0 \
            --quiet
        echo "  Created ${rule_name} (tcp:${port} → tag ${tag})"
    fi
done

# Settle on the public hostname now — the domain if the operator chose one,
# otherwise the VM's public IP. This is what setup.sh will bake into the
# cert SAN, Grafana root_url, Prometheus external-url, and the summary URLs.
if $USE_DOMAIN; then
    EXTERNAL_HOST_VALUE="$DOMAIN"
else
    EXTERNAL_HOST_VALUE="$VM_IP"
fi

# ── [3/4] Run bootstrap on the VM (pulls everything from GitHub) ──────────────
log "[3/4] Running bootstrap on VM"

# Pass the API key non-interactively via a temporary env file on the VM.
{
    printf 'export WEATHER_API_KEY=%q\n' "$WEATHER_API_KEY"
    printf 'export USE_TAILSCALE=false\n'
    printf 'export EXTERNAL_HOST=%q\n' "$EXTERNAL_HOST_VALUE"
} | gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" \
    --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag='-o SendEnv=-LC_*' \
    --command="cat > /tmp/exam_env.sh && chmod 600 /tmp/exam_env.sh"

# Source the env, curl bootstrap.sh, and run as root with the env preserved.
gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" \
    --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag='-o SendEnv=-LC_*' \
    --command="source /tmp/exam_env.sh && \
               curl -fsSL '${REPO_RAW_URL}/bootstrap.sh' \
                 | sudo --preserve-env=WEATHER_API_KEY,USE_TAILSCALE,EXTERNAL_HOST bash && \
               rm -f /tmp/exam_env.sh"

# ── [4/4] Domain: DNS update + TLS cert ───────────────────────────────────────
if $USE_DOMAIN; then
    log "[4/4] Configuring domain"

    AUTH=$(printf '%s:%s' "$CPANEL_USER" "$CPANEL_PASS" | base64)
    FETCH=$(curl -sf -H "Authorization: Basic $AUTH" \
        "${CPANEL_HOST}/json-api/cpanel?cpanel_jsonapi_module=ZoneEdit&cpanel_jsonapi_func=fetchzone_records&domain=${DNS_ZONE}&type=A&name=${DOMAIN}.")
    LINE=$(printf '%s' "$FETCH" | python3 -c \
        "import sys,json; r=json.load(sys.stdin).get('cpanelresult',{}).get('data',[]); print(r[0].get('line','') if r else '')" 2>/dev/null || true)

    if [[ -n "$LINE" ]]; then
        curl -sf -H "Authorization: Basic $AUTH" \
            "${CPANEL_HOST}/json-api/cpanel?cpanel_jsonapi_module=ZoneEdit&cpanel_jsonapi_func=edit_zone_record&domain=${DNS_ZONE}&line=${LINE}&type=A&name=${DOMAIN}.&address=${VM_IP}&ttl=300" > /dev/null
        echo "  Updated $DOMAIN -> $VM_IP"
    else
        curl -sf -H "Authorization: Basic $AUTH" \
            "${CPANEL_HOST}/json-api/cpanel?cpanel_jsonapi_module=ZoneEdit&cpanel_jsonapi_func=add_zone_record&domain=${DNS_ZONE}&type=A&name=${DOMAIN}.&address=${VM_IP}&ttl=300" > /dev/null
        echo "  Created $DOMAIN -> $VM_IP"
    fi
    unset CPANEL_PASS AUTH

    # Poll public DNS until it returns the right IP, instead of guessing with
    # a fixed sleep. dig isn't always installed (no Windows, minimal Linux), so
    # we fall back to the old sleep if it's missing.
    if command -v dig &>/dev/null; then
        echo "  Polling DNS for $DOMAIN -> $VM_IP (up to 180s)..."
        for i in $(seq 1 60); do
            resolved=$(dig +short +time=2 +tries=1 "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1)
            if [[ "$resolved" == "$VM_IP" ]]; then
                echo "  DNS resolved after $((i * 3))s"
                break
            fi
            sleep 3
        done
        [[ "${resolved:-}" != "$VM_IP" ]] && echo "  Warning: DNS not yet propagated (saw '${resolved:-}'), continuing — certbot may still succeed via authoritative lookup"
    else
        echo "  dig not installed, sleeping 60s for DNS propagation"
        sleep 60
    fi

    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" \
        --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag='-o SendEnv=-LC_*' \
        --command="sudo apt-get install -y -qq certbot python3-certbot-nginx && \
                   sudo certbot --nginx -d ${DOMAIN} \
                       --non-interactive --agree-tos --email ${CERTBOT_EMAIL} && \
                   sudo systemctl reload nginx"
    echo "  TLS certificate issued for $DOMAIN"
fi

# setup.sh on the VM already printed a full summary box with services, URLs,
# Grafana password, and the Vault unseal key — no need to repeat it locally.
# If the domain path ran, certbot's own messages above confirm the cert. Done.
if $USE_DOMAIN; then
    echo "  Provisioning complete. App at: https://${DOMAIN}"
else
    echo "  Provisioning complete. App at: https://${EXTERNAL_HOST_VALUE}  (self-signed cert)"
fi
