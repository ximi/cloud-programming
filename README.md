# Exam Infrastructure — Automated Deployment

Single-command provisioning of a complete, secure, and observable stack.

## Stack

| Component | Tool | Purpose |
|---|---|---|
| Secret Management | HashiCorp Vault | Stores API keys — no hardcoded secrets in app |
| Application | Python (stdlib only) | Weather app, fetches API key from Vault at runtime |
| Reverse Proxy | Nginx | Sole entry point, HTTP→HTTPS redirect |
| Monitoring | Prometheus + Node Exporter + Grafana | CPU & RAM dashboard |
| Dynamic DNS | cPanel API | Updates `exam.maximilianzimmer.com` to VM's public IP |

## Deployment

### Option A — GCP (recommended)

Provisions a free-tier `e2-micro` VM on Google Cloud, runs the setup script on it, and optionally configures the custom domain with a real TLS cert.

```bash
bash provision.sh
```

**Prerequisites:**
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

The provisioner prompts for everything upfront, then runs fully unattended:

```
  OpenWeatherMap API key: <hidden>
  Configure custom domain (exam.maximilianzimmer.com)? [y/N]:

  # If yes:
  cPanel host     : <hidden>
  cPanel username : <hidden>
  cPanel password : <hidden>
  Email (certbot) : <hidden>
```

What `provision.sh` does:
1. Creates an `e2-micro` VM in `us-central1-a` (GCP always-free tier)
2. Opens firewall ports 80, 443, 3000, 9090
3. Copies and runs `setup_exam.sh` non-interactively
4. (Optional) Updates the DNS A record via cPanel API, waits for propagation, and issues a Let's Encrypt cert via certbot

### Option B — local/any VM

SSH into any fresh Ubuntu/Debian VM and run:

```bash
sudo bash setup_exam.sh
```

The script prompts for credentials interactively (nothing stored in shell history):

```
  OpenWeatherMap API key: <hidden>
  Configure Tailscale + custom domain? [y/N]:

  # If yes:
  Tailscale auth key : <hidden>
  cPanel host        : <hidden>
  cPanel username    : <hidden>
  cPanel password    : <hidden>
```

## What `setup_exam.sh` does

1. Installs all packages from scratch (Vault, Grafana via apt; Prometheus + Node Exporter via binary; Nginx via apt)
2. Initialises and unseals Vault, stores secrets — installs auto-unseal service so reboots don't break the app
3. Starts Node Exporter, Prometheus, Grafana
4. Deploys the web app as a systemd service (`appuser`, no root, token injected via env file)
5. Configures Nginx as reverse proxy with TLS (Let's Encrypt if available, self-signed fallback with correct SAN)
6. Configures Grafana datasource and CPU/RAM dashboard via API
7. (Optional) Connects Tailscale, updates DNS A record for `exam.maximilianzimmer.com`

## Access

| Service | URL |
|---|---|
| Application | `https://exam.maximilianzimmer.com` or `https://<VM-IP>` |
| Grafana | `http://<VM-IP>:3000` — admin / admin |
| Prometheus | `http://<VM-IP>:9090` |
| Vault UI | `http://127.0.0.1:8200/ui` — internal only |

## Security notes

- Application source contains no secrets — API key is fetched from Vault at runtime
- Vault token is injected via `/etc/webapp.env` (mode 600, owned by `appuser`)
- `/metrics` endpoint is blocked at the Nginx level
- All credentials are prompted interactively and never written to shell history
