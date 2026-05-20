#!/usr/bin/env bash
# Full infrastructure provisioning from a bare Ubuntu/Debian VM.
# Usage: sudo bash setup.sh
set -euo pipefail

PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-2.52.0}"
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.8.2}"
export VAULT_ADDR="http://127.0.0.1:8200"
export DEBIAN_FRONTEND=noninteractive
# Silence Ubuntu 22.04's needrestart post-apt hook. We restart the services we
# care about explicitly below, and the "Running kernel seems to be up-to-date"
# spam after every apt-get install is just noise.
export NEEDRESTART_SUSPEND=1        # disable the hook entirely (needrestart >= 3.5)
export NEEDRESTART_MODE=a           # fallback for older versions: auto, no prompts
# Pin the locale to something Ubuntu always has, regardless of what the SSH
# client forwarded. macOS ships LC_CTYPE=UTF-8 (no language prefix), which
# isn't a valid locale name on Linux — perl, dpkg, certbot et al. all warn.
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
unset LC_CTYPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo; echo "=== $* ==="; }

# ── Prompt for required and optional configuration ────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────┐"
echo "│            Infrastructure Setup                 │"
echo "└─────────────────────────────────────────────────┘"
echo ""

# All `read` calls below use `< /dev/tty` so they work when this script is
# invoked via `curl ... | sudo bash` (where stdin is the pipe, not the terminal).
if [[ -z "${WEATHER_API_KEY:-}" ]]; then
    while true; do
        read -rsp "  OpenWeatherMap API key: " WEATHER_API_KEY < /dev/tty; echo
        [[ -n "$WEATHER_API_KEY" ]] && break
        echo "  API key cannot be empty. Please try again."
    done
fi

if [[ -z "${USE_TAILSCALE:-}" ]]; then
    echo ""
    read -rp "Set up Tailscale + custom domain? [y/N]: " _ts_answer < /dev/tty
    USE_TAILSCALE=false
    [[ "$_ts_answer" =~ ^[yY]([eE][sS])?$ ]] && USE_TAILSCALE=true
fi

if $USE_TAILSCALE; then
    [[ -z "${TAILSCALE_AUTH_KEY:-}" ]] && { echo ""; read -rsp "  Tailscale auth key   : " TAILSCALE_AUTH_KEY < /dev/tty; echo; }
    [[ -z "${EXTERNAL_HOST:-}" ]]      && { read -rp  "  Custom domain (FQDN) : " EXTERNAL_HOST     < /dev/tty; echo; }
    [[ -z "${CPANEL_HOST:-}" ]]        && { read -rp  "  cPanel host          : " CPANEL_HOST       < /dev/tty; echo; }
    [[ -z "${CPANEL_USER:-}" ]]        && { read -rp  "  cPanel username      : " CPANEL_USER       < /dev/tty; echo; }
    [[ -z "${CPANEL_PASS:-}" ]]        && { read -rsp "  cPanel password      : " CPANEL_PASS       < /dev/tty; echo; }
    [[ -z "${CERTBOT_EMAIL:-}" ]]      && { read -rp  "  Email (Let's Encrypt): " CERTBOT_EMAIL     < /dev/tty; echo; }
    echo ""
fi

# ── Detect external host (domain if provided, else public IP) ─────────────────
# Used for the self-signed cert SAN, Grafana root_url, Prometheus external-url,
# and the access URLs printed in the summary. Caller can override with
# EXTERNAL_HOST=... in the env (provision.sh passes the domain or VM public IP).
if [[ -z "${EXTERNAL_HOST:-}" ]]; then
    # The Tailscale block above prompts for EXTERNAL_HOST (the operator's
    # custom domain). The non-Tailscale path auto-detects from cloud metadata
    # or local interfaces. Each step is validated for non-empty output — a
    # previous version used a `||` chain that accepted exit-0-with-empty-body
    # responses (api4.my-ip.io does this sometimes) and short-circuited the rest.

    # 1. GCP metadata (1s connect timeout fails fast on non-cloud VMs).
    EXTERNAL_HOST=$(curl -fs --max-time 2 --connect-timeout 1 \
        -H 'Metadata-Flavor: Google' \
        http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip \
        2>/dev/null || true)

    # 2. AWS / Azure / DigitalOcean metadata (same link-local address).
    if [[ -z "$EXTERNAL_HOST" ]]; then
        EXTERNAL_HOST=$(curl -fs --max-time 2 --connect-timeout 1 \
            http://169.254.169.254/latest/meta-data/public-ipv4 \
            2>/dev/null || true)
    fi

    # 3. First non-loopback IPv4 on a real interface — the LAN address
    #    a browser on the same network would use. Correct default for
    #    local/NAT'd VMs.
    if [[ -z "$EXTERNAL_HOST" ]]; then
        EXTERNAL_HOST=$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 | head -1)
    fi

    # 4. Public-IP echo as a last resort. Forced to IPv4 (-4) so the
    #    service doesn't return the box's public IPv6, which is rarely
    #    what you want as a cert SAN.
    if [[ -z "$EXTERNAL_HOST" ]]; then
        EXTERNAL_HOST=$(curl -fs --max-time 3 -4 https://ifconfig.me/ip 2>/dev/null || true)
        [[ -z "$EXTERNAL_HOST" ]] && EXTERNAL_HOST=$(curl -fs --max-time 3 -4 https://api.ipify.org 2>/dev/null || true)
    fi
fi

# Final fallback for the friendly path: prompt if all four came up empty.
if [[ -z "$EXTERNAL_HOST" ]] && [[ -r /dev/tty ]]; then
    echo "  Could not auto-detect external host."
    read -rp "  Enter the address you'll use to reach this VM (IP or hostname): " EXTERNAL_HOST < /dev/tty
fi

if [[ -z "$EXTERNAL_HOST" ]]; then
    echo "ERROR: External host is required."
    echo "  Auto-detection failed and no TTY was available to prompt."
    echo "  Re-run with an explicit value, e.g.:"
    echo "    curl … | sudo EXTERNAL_HOST=192.168.1.50 bash"
    exit 1
fi
echo "  External host: $EXTERNAL_HOST"

if [[ "$EXTERNAL_HOST" =~ ^[0-9.]+$ ]]; then
    CERT_SAN_TYPE="IP"
else
    CERT_SAN_TYPE="DNS"
fi

# ── Ensure swap ───────────────────────────────────────────────────────────────
# The full stack (Vault + Prometheus + Grafana + node_exporter + Nginx + the
# webapp) plus apt during install is enough to push a 1 GB e2-micro over the
# OOM line. A 2 GB swap file gives the kernel somewhere to spill cold pages so
# brief memory spikes don't kill long-running processes. Idempotent: skipped
# if any swap is already configured (e.g. on machines with larger plans).
if [[ $(swapon --show --noheadings 2>/dev/null | wc -l) -eq 0 ]]; then
    log "Creating 2 GB swap file at /swapfile"
    fallocate -l 2G /swapfile 2>/dev/null \
        || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Don't lean on swap too eagerly — only when RAM is genuinely under
    # pressure. Default of 60 is desktop-tuned; lower is better for a server.
    sysctl -w vm.swappiness=10 >/dev/null
    grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
else
    echo "  Swap already configured, skipping"
fi

# ── [1/7] Install all packages ─────────────────────────────────────────────────
log "[1/7] Installing packages"

apt-get update -qq
apt-get install -y -qq nginx python3 curl openssl gpg apt-transport-https lsb-release ca-certificates

# HashiCorp Vault (official apt repo)
if ! command -v vault &>/dev/null; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq && apt-get install -y -qq vault
fi

# Grafana (official apt repo)
if ! command -v grafana-server &>/dev/null; then
    curl -fsSL https://apt.grafana.com/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/grafana.gpg
    echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq && apt-get install -y -qq grafana
fi

# Prometheus (binary release)
if ! command -v prometheus &>/dev/null; then
    ARCH=$(dpkg --print-architecture)
    TMP=$(mktemp -d)
    curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}.tar.gz" \
        | tar -xz -C "$TMP"
    install -m755 "$TMP/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}/prometheus" /usr/local/bin/
    install -m755 "$TMP/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}/promtool" /usr/local/bin/
    mkdir -p /etc/prometheus /var/lib/prometheus
    cp -r "$TMP/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}/consoles" /etc/prometheus/
    cp -r "$TMP/prometheus-${PROMETHEUS_VERSION}.linux-${ARCH}/console_libraries" /etc/prometheus/
    rm -rf "$TMP"
    id prometheus &>/dev/null || useradd -r -s /usr/sbin/nologin prometheus
    chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
fi

# Node Exporter (binary release)
if ! command -v node_exporter &>/dev/null; then
    ARCH=$(dpkg --print-architecture)
    TMP=$(mktemp -d)
    curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
        | tar -xz -C "$TMP"
    install -m755 "$TMP/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
    rm -rf "$TMP"
    id node_exporter &>/dev/null || useradd -r -s /usr/sbin/nologin node_exporter
fi

# Tailscale (official install script)
if $USE_TAILSCALE && ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# ── [2/7] Vault: configure, start, init, unseal, store secrets ─────────────────
log "[2/7] Configuring Vault"

mkdir -p /opt/vault/data /etc/vault.d
id vault &>/dev/null || useradd -r -s /usr/sbin/nologin vault
chown -R vault:vault /opt/vault/data
touch /etc/vault.d/vault.env

cat > /etc/vault.d/vault.hcl << 'EOF'
ui = true

# Don't mlockall() — on small VMs (e2-micro, even some e2-small) Vault would
# pin ~400-500 MB of RAM in place, push everything else into swap, and the
# whole system would drown in I/O wait. The security trade-off (Vault pages
# may end up on swap) is acceptable here; in production you'd give Vault
# enough RAM that mlock isn't catastrophic.
disable_mlock = true

storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}
EOF

systemctl daemon-reload
systemctl enable vault
systemctl restart vault

# Wait for Vault's HTTP listener to be up. vault.service is Type=simple, so
# `systemctl restart` returns the moment the process is forked — well before
# the API is ready. A bare `sleep 3` was too short on some VMs and the
# resulting connection-refused looks identical to "already initialized" if we
# only grep for one line of `vault status` output.
for _ in $(seq 1 30); do
    vault status 2>&1 | grep -q "Initialized" && break
    sleep 1
done

VAULT_STATUS=$(vault status 2>&1 || true)

if ! echo "$VAULT_STATUS" | grep -q "Initialized"; then
    echo "ERROR: Vault did not become reachable within 30s."
    echo "  Last vault status output:"
    echo "$VAULT_STATUS" | sed 's/^/    /'
    echo "  Recent vault logs:"
    journalctl -u vault -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || true
    exit 1
fi

if echo "$VAULT_STATUS" | grep -q "Initialized.*true"; then
    echo "ERROR: Vault is already initialized. This script expects a fresh Vault."
    echo "  To start over:"
    echo "    sudo systemctl stop vault && sudo rm -rf /opt/vault/data && sudo systemctl start vault"
    exit 1
fi

# Reachable and uninitialized — proceed.
INIT_OUT=$(vault operator init -key-shares=1 -key-threshold=1 -format=json)
UNSEAL_KEY=$(echo "$INIT_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
ROOT_TOKEN=$(echo "$INIT_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['root_token'])")

# Show the unseal key prominently. It is the operator's responsibility from
# this point onward — we do NOT write it to disk.
echo ""
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║                                                                       ║"
echo "║   VAULT UNSEAL KEY  —  SAVE THIS NOW.  IT IS NOT WRITTEN TO DISK.     ║"
echo "║                                                                       ║"
printf  "║   %-67s ║\n" "$UNSEAL_KEY"
echo "║                                                                       ║"
echo "║   You will need it to unseal Vault after any reboot.                  ║"
echo "║   Recovery command:  sudo /opt/unseal-vault.sh                        ║"
echo "║                                                                       ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""

if [[ -r /dev/tty ]]; then
    read -rp "  Press ENTER once you have saved the unseal key... " _ack < /dev/tty || true
fi

vault operator unseal "$UNSEAL_KEY" >/dev/null
unset UNSEAL_KEY

export VAULT_TOKEN="$ROOT_TOKEN"

# Helper script for re-unsealing Vault after a reboot. The unseal key is not
# persisted anywhere — the operator must enter it interactively.
cat > /opt/unseal-vault.sh << 'UNSEALEOF'
#!/usr/bin/env bash
# Unseal Vault interactively after a reboot, then restart the dependent app.
# Usage: sudo /opt/unseal-vault.sh
set -euo pipefail

export VAULT_ADDR="http://127.0.0.1:8200"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo /opt/unseal-vault.sh"; exit 1
fi

systemctl is-active --quiet vault || systemctl start vault
sleep 2

if vault status 2>&1 | grep -q "Sealed.*false"; then
    echo "Vault is already unsealed."; exit 0
fi

read -rsp "Enter Vault unseal key: " UNSEAL_KEY
echo
vault operator unseal "$UNSEAL_KEY" >/dev/null
unset UNSEAL_KEY

systemctl restart webapp
echo "Vault unsealed. webapp.service restarted."
UNSEALEOF
chmod 755 /opt/unseal-vault.sh

vault secrets enable -path=secret kv 2>/dev/null || true

vault kv put secret/weather \
    api_key="$WEATHER_API_KEY" \
    app_name="WeatherApp"

if $USE_TAILSCALE; then
    vault kv put secret/cpanel \
        host="$CPANEL_HOST" \
        username="$CPANEL_USER" \
        password="$CPANEL_PASS"
    unset CPANEL_PASS
fi

# Least-privilege policy and token for the application.
# The app does not get the root token — it gets a token that can only read
# the one secret it needs.
vault policy write app-read - <<'POLICY'
path "secret/weather" {
  capabilities = ["read"]
}
POLICY

APP_TOKEN=$(vault token create \
    -policy=app-read \
    -ttl=8760h \
    -renewable=true \
    -format=json \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

# Same pattern for the DDNS updater — it only needs to read secret/cpanel.
# We only create this token when the Tailscale/DDNS path is going to run.
DDNS_TOKEN=""
if $USE_TAILSCALE; then
    vault policy write ddns-read - <<'POLICY'
path "secret/cpanel" {
  capabilities = ["read"]
}
POLICY
    DDNS_TOKEN=$(vault token create \
        -policy=ddns-read \
        -ttl=8760h \
        -renewable=true \
        -format=json \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")
fi

# ── [3/7] Monitoring: units, prometheus config, start ──────────────────────────
log "[3/7] Configuring monitoring stack"

cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus Monitoring System
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \\
    --config.file=/etc/prometheus/prometheus.yml \\
    --storage.tsdb.path=/var/lib/prometheus/ \\
    --storage.tsdb.retention.time=7d \\
    --web.console.templates=/etc/prometheus/consoles \\
    --web.console.libraries=/etc/prometheus/console_libraries \\
    --web.external-url=https://${EXTERNAL_HOST}/prometheus/ \\
    --web.route-prefix=/
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Grafana sub-path config so it can be served as /grafana/ behind Nginx.
mkdir -p /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/override.conf <<EOF
[Service]
Environment=GF_SERVER_ROOT_URL=https://${EXTERNAL_HOST}/grafana/
Environment=GF_SERVER_SERVE_FROM_SUB_PATH=true
EOF

cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
  - job_name: "node_exporter"
    static_configs:
      - targets: ["localhost:9100"]
EOF
chown prometheus:prometheus /etc/prometheus/prometheus.yml

systemctl daemon-reload
systemctl enable node_exporter prometheus grafana-server
# Restart (not just start) so Grafana picks up the sub-path override even when
# apt-get install grafana already auto-started it earlier in this script.
systemctl restart node_exporter prometheus grafana-server
sleep 5

# ── [4/7] Web application: infrastructure ─────────────────────────────────────
# This section sets up everything the app NEEDS (user, env file, systemd unit)
# but the actual application code is deployed by deploy_app.sh, which is called
# at the end of this script. That separation lets you re-deploy app code later
# without touching the infrastructure.
log "[4/7] Configuring web application infrastructure"

id appuser &>/dev/null || useradd -r -s /usr/sbin/nologin appuser

# Install the DNS updater (used by the optional Tailscale path in [7/7]).
if [[ -f "$SCRIPT_DIR/ddns-update.py" ]]; then
    install -m 755 "$SCRIPT_DIR/ddns-update.py" /opt/ddns-update.py
fi

cat > /etc/systemd/system/webapp.service << 'EOF'
[Unit]
Description=Secure Web Application (Vault-backed)
After=network.target vault.service

[Service]
Type=simple
User=appuser
Environment=VAULT_ADDR=http://127.0.0.1:8200
EnvironmentFile=/etc/webapp.env
ExecStart=/usr/bin/python3 /opt/webapp.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Application gets the LEAST-PRIVILEGE token (created above), not the root token.
printf 'VAULT_TOKEN=%s\n' "$APP_TOKEN" > /etc/webapp.env
chmod 600 /etc/webapp.env
chown appuser:appuser /etc/webapp.env

systemctl daemon-reload
systemctl enable webapp
# Service is actually started by deploy_app.sh (which puts webapp.py in place first).

# ── [5/7] Nginx: reverse proxy with TLS ───────────────────────────────────────
log "[5/7] Configuring Nginx"

LE_CERT="/etc/letsencrypt/live/${EXTERNAL_HOST}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${EXTERNAL_HOST}/privkey.pem"
SS_CERT="/etc/ssl/certs/exam-selfsigned.pem"
SS_KEY="/etc/ssl/private/exam-selfsigned.key"

# Use a Let's Encrypt cert only if one already exists for this host (a real
# domain has been provisioned out-of-band). For an IP-only host we skip this
# check entirely — LE doesn't issue for raw IPs.
if [[ "$CERT_SAN_TYPE" == "DNS" ]] && [ -f "$LE_CERT" ] && [ -f "$LE_KEY" ]; then
    SSL_CERT="$LE_CERT"
    SSL_KEY="$LE_KEY"
    echo "  Using Let's Encrypt certificate for $EXTERNAL_HOST"
else
    echo "  Generating self-signed certificate for $EXTERNAL_HOST"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SS_KEY" -out "$SS_CERT" \
        -subj "/CN=${EXTERNAL_HOST}" \
        -addext "subjectAltName=${CERT_SAN_TYPE}:${EXTERNAL_HOST}"
    chmod 600 "$SS_KEY"
    SSL_CERT="$SS_CERT"
    SSL_KEY="$SS_KEY"
fi

cat > /etc/nginx/sites-available/default << NGINXEOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Security headers — applied at the server level so they cover the app,
    # Grafana, and Prometheus. HSTS pins the browser to HTTPS for a year;
    # nosniff blocks MIME-confusion attacks; the referrer policy prevents
    # leaking the full URL (including any query string) to cross-origin links.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff"                            always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin"    always;

    # Listed explicitly so \`certbot --nginx -d ${EXTERNAL_HOST}\` can find this
    # block; \`_\` keeps it as the default for any other host header.
    server_name ${EXTERNAL_HOST} _;

    location / {
        proxy_pass         http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    # Grafana — served at /grafana/ via sub-path config (see grafana-server override).
    location /grafana/ {
        proxy_pass         http://127.0.0.1:3000;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        # Grafana live updates use websockets.
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }

    # Prometheus serves at / internally (--web.route-prefix=/) and uses
    # external-url=/prometheus/ only for generated absolute links. So Nginx
    # strips the /prometheus/ prefix here (trailing slash on proxy_pass).
    # This also means Grafana's localhost:9090 datasource Just Works without
    # any path suffix.
    location /prometheus/ {
        proxy_pass         http://127.0.0.1:9090/;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

nginx -t && systemctl reload nginx

# ── [6/7] Grafana: rotate admin password, then datasource + dashboard ─────────
log "[6/7] Configuring Grafana"
sleep 5

# Rotate the admin password BEFORE configuring datasource/dashboard, so all the
# API calls use the new credential. grafana-cli writes directly to the DB,
# which is more reliable than `PUT /api/user/password` (the latter refuses on
# Grafana 10+'s "first login must change password" state).
GRAFANA_PASS=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)
# --homepath is required as of Grafana 12+ — without it grafana-cli can't
# locate its config defaults and exits with "Grafana-server Init Failed".
if grafana-cli --homepath=/usr/share/grafana admin reset-admin-password "$GRAFANA_PASS" >/dev/null 2>&1; then
    echo "  Grafana admin password rotated"
else
    echo "  Warning: grafana-cli reset-admin-password failed — keeping admin/admin"
    GRAFANA_PASS="admin"
fi
vault kv put secret/grafana username=admin password="$GRAFANA_PASS" >/dev/null

curl -sf -u "admin:${GRAFANA_PASS}" -X POST http://localhost:3000/grafana/api/datasources \
  -H "Content-Type: application/json" \
  -d '{"name":"Prometheus","type":"prometheus","uid":"prometheus","url":"http://localhost:9090","access":"proxy","isDefault":true}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('  Datasource:', d.get('message','ok'))" 2>/dev/null \
  || echo "  Datasource already exists"

curl -sf -u "admin:${GRAFANA_PASS}" -X POST http://localhost:3000/grafana/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d '{
    "dashboard": {
      "title": "VM Resources - CPU & RAM",
      "refresh": "15s",
      "panels": [
        {
          "id": 1,
          "type": "timeseries",
          "title": "CPU Usage (%)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
          "targets": [{
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "expr": "100 - (avg by(instance)(rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)",
            "legendFormat": "CPU %"
          }],
          "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}}
        },
        {
          "id": 2,
          "type": "timeseries",
          "title": "RAM Usage (%)",
          "datasource": {"type": "prometheus", "uid": "prometheus"},
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
          "targets": [{
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "expr": "100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))",
            "legendFormat": "RAM %"
          }],
          "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}}
        }
      ],
      "time": {"from": "now-15m", "to": "now"},
      "schemaVersion": 38
    },
    "overwrite": true
  }' | python3 -c "import sys,json; d=json.load(sys.stdin); print('  Dashboard:', d.get('status','?'), d.get('url',''))" 2>/dev/null \
  || echo "  Dashboard creation attempted"

# ── Application deployment ────────────────────────────────────────────────────
# Delegate to the dedicated app deployment script. On initial setup we use the
# tarball-bundled webapp.py (already extracted next to this script) instead of
# letting deploy_app.sh re-download it from GitHub — saves one round-trip and
# keeps the initial provision working even if the URL is temporarily unreachable.
# A later `sudo bash deploy_app.sh` (without WEBAPP_FILE) will pull from URL.
log "Deploying application via deploy_app.sh"
WEBAPP_FILE="$SCRIPT_DIR/webapp.py" bash "$SCRIPT_DIR/deploy_app.sh"

# ── [7/7] Tailscale + DNS, or show access IP ──────────────────────────────────
log "[7/7] Network access"

if $USE_TAILSCALE; then
    echo "  Connecting to Tailscale..."
    tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname=exam-vm
    unset TAILSCALE_AUTH_KEY
    sleep 3

    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

    if [ -n "$TAILSCALE_IP" ]; then
        echo "  Tailscale IP: ${TAILSCALE_IP}"
        echo "  Updating DNS for ${EXTERNAL_HOST}..."

        # Use the least-privilege DDNS token, not the root token. Pass the
        # Tailscale IP explicitly — otherwise the script falls back to a
        # public-IP echo and points DNS at the home router's WAN, which is
        # the opposite of what Tailscale is for here. DDNS_DOMAIN tells the
        # script which FQDN to maintain (no longer hardcoded).
        VAULT_TOKEN="$DDNS_TOKEN" VAULT_ADDR="$VAULT_ADDR" \
            DDNS_DOMAIN="$EXTERNAL_HOST" \
            python3 /opt/ddns-update.py "$TAILSCALE_IP"
    else
        echo "  Warning: could not get Tailscale IP, DNS not updated"
    fi

    # ── Let's Encrypt cert via DNS-01 ──────────────────────────────────────
    # HTTP-01 doesn't work here: the A record points to a 100.x.x.x Tailscale
    # IP, which LE's validator can't reach from the public internet. DNS-01
    # sidesteps this — we prove control via a TXT record on the public zone,
    # which is unaffected by where the A record points.
    if [[ -n "${CERTBOT_EMAIL:-}" ]]; then
        log "Issuing Let's Encrypt cert via DNS-01"
        apt-get install -y -qq certbot

        install -m 755 "$SCRIPT_DIR/cpanel-dns-hook.py" /opt/cpanel-dns-hook.py

        # Vault token for the hook script lives in a file (mode 600) so it
        # doesn't end up baked into certbot's renewal config under
        # /etc/letsencrypt/renewal/<domain>.conf.
        cat > /etc/cpanel-dns-hook.env <<EOF
VAULT_ADDR=$VAULT_ADDR
VAULT_TOKEN=$DDNS_TOKEN
EOF
        chmod 600 /etc/cpanel-dns-hook.env

        if certbot certonly \
            --manual --preferred-challenges dns \
            --manual-auth-hook    '/opt/cpanel-dns-hook.py auth' \
            --manual-cleanup-hook '/opt/cpanel-dns-hook.py cleanup' \
            -d "$EXTERNAL_HOST" \
            --non-interactive --agree-tos --email "$CERTBOT_EMAIL"; then

            # Swap the nginx cert paths from self-signed to LE, then reload.
            sed -i \
                -e "s|/etc/ssl/certs/exam-selfsigned.pem|/etc/letsencrypt/live/$EXTERNAL_HOST/fullchain.pem|" \
                -e "s|/etc/ssl/private/exam-selfsigned.key|/etc/letsencrypt/live/$EXTERNAL_HOST/privkey.pem|" \
                /etc/nginx/sites-available/default
            nginx -t && systemctl reload nginx
            echo "  Nginx now serving Let's Encrypt cert for $EXTERNAL_HOST"
        else
            echo "  certbot failed — keeping the self-signed cert (still TLS, just untrusted)"
        fi
    fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────────────────────────────┐"
echo "│                  SETUP COMPLETE                      │"
echo "├──────────────────────┬───────────────────────────────┤"
for svc in vault webapp nginx prometheus node_exporter grafana-server; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    printf "│  %-20s │  %-29s│\n" "$svc" "$status"
done
echo "├──────────────────────┴───────────────────────────────┤"
printf "│  %-52s │\n" "App:        https://${EXTERNAL_HOST}"
printf "│  %-52s │\n" "Grafana:    https://${EXTERNAL_HOST}/grafana/"
printf "│  %-52s │\n" "  user: admin  pass: ${GRAFANA_PASS}"
printf "│  %-52s │\n" "Prometheus: https://${EXTERNAL_HOST}/prometheus/"
echo "├──────────────────────────────────────────────────────┤"
printf "│  %-52s │\n" "Grafana password also stored in Vault: secret/grafana"
echo "└──────────────────────────────────────────────────────┘"
