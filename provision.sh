#!/usr/bin/env bash
# Provision a free-tier GCP VM and run setup_exam.sh on it.
# Usage: bash provision.sh
set -euo pipefail

INSTANCE_NAME="exam-vm"
ZONE="us-central1-a"
MACHINE_TYPE="e2-micro"
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"
DOMAIN="exam.maximilianzimmer.com"
DNS_ZONE="maximilianzimmer.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── Collect credentials ────────────────────────────────────────────────────────
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
    read -rsp "  OpenWeatherMap API key: " WEATHER_API_KEY; echo
    [[ -n "$WEATHER_API_KEY" ]] && break
    echo "  API key cannot be empty."
done

echo ""
read -rp "  Configure custom domain ($DOMAIN)? [y/N]: " _domain_answer
USE_DOMAIN=false
[[ "${_domain_answer,,}" =~ ^y(es)?$ ]] && USE_DOMAIN=true

CPANEL_HOST="" CPANEL_USER="" CPANEL_PASS="" CERTBOT_EMAIL=""
if $USE_DOMAIN; then
    echo ""
    read -rp  "  cPanel host     : " CPANEL_HOST; echo
    read -rp  "  cPanel username : " CPANEL_USER; echo
    read -rsp "  cPanel password : " CPANEL_PASS; echo
    read -rp  "  Email (certbot) : " CERTBOT_EMAIL; echo
fi

# ── [1/3] Create VM ────────────────────────────────────────────────────────────
log "[1/3] Creating VM"

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
echo "  Public IP: $VM_IP"

# ── [2/3] Firewall ─────────────────────────────────────────────────────────────
log "[2/3] Configuring firewall"

for rule_spec in "allow-exam-grafana:3000" "allow-exam-prometheus:9090"; do
    rule_name="${rule_spec%%:*}"
    port="${rule_spec##*:}"
    if gcloud compute firewall-rules describe "$rule_name" --quiet &>/dev/null; then
        echo "  Rule already exists: $rule_name"
    else
        gcloud compute firewall-rules create "$rule_name" \
            --allow="tcp:${port}" \
            --target-tags=exam-vm \
            --source-ranges=0.0.0.0/0 \
            --quiet
        echo "  Created rule: $rule_name (port $port)"
    fi
done

# ── [3/4] Run setup script ─────────────────────────────────────────────────────
log "[3/4] Running setup script"

{
    printf 'export WEATHER_API_KEY=%q\n' "$WEATHER_API_KEY"
    printf 'export USE_TAILSCALE=false\n'
} | gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" \
    --ssh-flag="-o StrictHostKeyChecking=no" \
    --command="cat > /tmp/exam_env.sh && chmod 600 /tmp/exam_env.sh"

gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" \
    --ssh-flag="-o StrictHostKeyChecking=no" \
    --command="cat > /tmp/setup_exam.sh && chmod +x /tmp/setup_exam.sh" \
    < "$SCRIPT_DIR/setup_exam.sh"

gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" \
    --ssh-flag="-o StrictHostKeyChecking=no" \
    --command="set -a; source /tmp/exam_env.sh; set +a; sudo -E bash /tmp/setup_exam.sh; rm -f /tmp/exam_env.sh"

# ── [4/4] Domain: DNS update + TLS cert ───────────────────────────────────────
if $USE_DOMAIN; then
    log "[4/4] Configuring domain"

    # Update DNS A record via cPanel API
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

    # Wait for DNS propagation then get a Let's Encrypt cert
    echo "  Waiting 60s for DNS to propagate..."
    sleep 60

    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" \
        --ssh-flag="-o StrictHostKeyChecking=no" \
        --command="sudo apt-get install -y -qq certbot python3-certbot-nginx && \
                   sudo certbot --nginx -d ${DOMAIN} \
                       --non-interactive --agree-tos --email ${CERTBOT_EMAIL} && \
                   sudo systemctl reload nginx"
    echo "  TLS certificate issued for $DOMAIN"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
if $USE_DOMAIN; then
    APP_URL="https://${DOMAIN}"
else
    APP_URL="https://${VM_IP}  (self-signed cert)"
fi

echo ""
echo "┌──────────────────────────────────────────────────┐"
echo "│  PROVISIONING COMPLETE                           │"
echo "├──────────────────────────────────────────────────┤"
printf "│  App       : %-35s │\n" "$APP_URL"
printf "│  Grafana   : %-35s │\n" "http://${VM_IP}:3000  (admin/admin)"
printf "│  Prometheus: %-35s │\n" "http://${VM_IP}:9090"
echo "└──────────────────────────────────────────────────┘"
