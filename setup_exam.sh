#!/usr/bin/env bash
# Full infrastructure provisioning from a bare Ubuntu/Debian VM.
# Usage: sudo bash setup_exam.sh
set -euo pipefail

PROMETHEUS_VERSION="2.52.0"
NODE_EXPORTER_VERSION="1.8.2"
export VAULT_ADDR="http://127.0.0.1:8200"
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo; echo "=== $* ==="; }

# ── Prompt for required and optional configuration ────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────┐"
echo "│         Exam Environment Setup Script           │"
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
    [[ "${_ts_answer,,}" =~ ^y(es)?$ ]] && USE_TAILSCALE=true
fi

if $USE_TAILSCALE; then
    [[ -z "${TAILSCALE_AUTH_KEY:-}" ]] && { echo ""; read -rsp "  Tailscale auth key : " TAILSCALE_AUTH_KEY < /dev/tty; echo; }
    [[ -z "${CPANEL_HOST:-}" ]]        && { read -rp  "  cPanel host        : " CPANEL_HOST       < /dev/tty; echo; }
    [[ -z "${CPANEL_USER:-}" ]]        && { read -rp  "  cPanel username    : " CPANEL_USER       < /dev/tty; echo; }
    [[ -z "${CPANEL_PASS:-}" ]]        && { read -rsp "  cPanel password    : " CPANEL_PASS       < /dev/tty; echo; }
    echo ""
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
sleep 3

if vault status 2>&1 | grep -q "Initialized.*false"; then
    INIT_OUT=$(vault operator init -key-shares=1 -key-threshold=1 -format=json)
    UNSEAL_KEY=$(echo "$INIT_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
    ROOT_TOKEN=$(echo "$INIT_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['root_token'])")
    printf '%s' "$UNSEAL_KEY" > /etc/vault.d/unseal.key
    printf '%s' "$ROOT_TOKEN" > /etc/vault.d/root.token
    chmod 600 /etc/vault.d/unseal.key /etc/vault.d/root.token
    chown vault:vault /etc/vault.d/unseal.key /etc/vault.d/root.token
else
    UNSEAL_KEY=$(cat /etc/vault.d/unseal.key)
    ROOT_TOKEN=$(cat /etc/vault.d/root.token)
fi

vault status 2>&1 | grep -q "Sealed.*true" && vault operator unseal "$UNSEAL_KEY"

export VAULT_TOKEN="$ROOT_TOKEN"

# Auto-unseal service — runs on every boot so the app never breaks after a reboot
cat > /etc/systemd/system/vault-unseal.service << 'EOF'
[Unit]
Description=Vault Auto-Unseal
After=vault.service
Requires=vault.service

[Service]
Type=oneshot
Environment=VAULT_ADDR=http://127.0.0.1:8200
ExecStartPre=/bin/sleep 3
ExecStart=/bin/sh -c 'vault status | grep -q "Sealed.*true" && vault operator unseal $(cat /etc/vault.d/unseal.key) || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vault-unseal
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

# ── [3/7] Monitoring: units, prometheus config, start ──────────────────────────
log "[3/7] Configuring monitoring stack"

cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus Monitoring System
After=network-online.target
Wants=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus/ \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries
Restart=on-failure

[Install]
WantedBy=multi-user.target
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
systemctl enable --now node_exporter
systemctl enable --now prometheus
systemctl enable --now grafana-server
sleep 3

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

LE_CERT="/etc/letsencrypt/live/exam.maximilianzimmer.com/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/exam.maximilianzimmer.com/privkey.pem"
SS_CERT="/etc/ssl/certs/exam-selfsigned.pem"
SS_KEY="/etc/ssl/private/exam-selfsigned.key"

if [ -f "$LE_CERT" ] && [ -f "$LE_KEY" ]; then
    SSL_CERT="$LE_CERT"
    SSL_KEY="$LE_KEY"
    echo "  Using Let's Encrypt certificate"
else
    echo "  Generating self-signed certificate..."
    if $USE_TAILSCALE; then
        CERT_CN="exam.maximilianzimmer.com"
        CERT_SAN="DNS:exam.maximilianzimmer.com"
    else
        VM_IP=$(hostname -I | awk '{print $1}')
        CERT_CN="$VM_IP"
        CERT_SAN="IP:$VM_IP"
    fi
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SS_KEY" -out "$SS_CERT" \
        -subj "/C=RO/ST=Sibiu/L=Sibiu/O=Exam/CN=${CERT_CN}" \
        -addext "subjectAltName=${CERT_SAN}" 2>/dev/null
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

    server_name _;

    location / {
        proxy_pass         http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    location /metrics {
        deny all;
    }
}
NGINXEOF

nginx -t && systemctl reload nginx

# ── [6/7] Grafana: datasource and dashboard ────────────────────────────────────
log "[6/7] Configuring Grafana"
sleep 5

curl -sf -X POST http://admin:admin@localhost:3000/api/datasources \
  -H "Content-Type: application/json" \
  -d '{"name":"Prometheus","type":"prometheus","url":"http://localhost:9090","access":"proxy","isDefault":true}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('  Datasource:', d.get('message','ok'))" 2>/dev/null \
  || echo "  Datasource already exists"

curl -sf -X POST http://admin:admin@localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d '{
    "dashboard": {
      "title": "VM Resources - CPU & RAM",
      "refresh": "5s",
      "panels": [
        {
          "id": 1,
          "type": "timeseries",
          "title": "CPU Usage (%)",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
          "targets": [{"expr": "100 - (avg by(instance)(rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)", "legendFormat": "CPU %"}],
          "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}}
        },
        {
          "id": 2,
          "type": "timeseries",
          "title": "RAM Usage (%)",
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
          "targets": [{"expr": "100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))", "legendFormat": "RAM %"}],
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
# Delegate to the dedicated app deployment script — same process the operator
# would use later to ship new versions of webapp.py.
log "Deploying application via deploy_app.sh"
bash "$SCRIPT_DIR/deploy_app.sh"

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
        echo "  Updating DNS for exam.maximilianzimmer.com..."

        VAULT_TOKEN="$ROOT_TOKEN" VAULT_ADDR="$VAULT_ADDR" \
            python3 /opt/ddns-update.py

        ACCESS_URL="https://exam.maximilianzimmer.com"
    else
        echo "  Warning: could not get Tailscale IP, DNS not updated"
        ACCESS_URL="https://$(hostname -I | awk '{print $1}')"
    fi
else
    VM_IP=$(hostname -I | awk '{print $1}')
    ACCESS_URL="https://${VM_IP}"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "┌──────────────────────────────────────────────────────┐"
echo "│            SETUP COMPLETE  —  1 COMMAND              │"
echo "├──────────────────────┬───────────────────────────────┤"
for svc in vault webapp nginx prometheus node_exporter grafana-server; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    printf "│  %-20s │  %-29s│\n" "$svc" "$status"
done
echo "├──────────────────────┴───────────────────────────────┤"
printf "│  %-52s │\n" "App:        ${ACCESS_URL}"
printf "│  %-52s │\n" "Grafana:    http://$(hostname -I | awk '{print $1}'):3000  (admin/admin)"
printf "│  %-52s │\n" "Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
echo "└──────────────────────────────────────────────────────┘"
