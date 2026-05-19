# Exam Infrastructure — Automated Deployment

Single-command provisioning of a complete, secure, and observable stack on a bare Ubuntu/Debian VM.

## Stack

| Component | Tool | Purpose |
|---|---|---|
| Secret Management | HashiCorp Vault | Stores API keys — no hardcoded secrets in app |
| Application | Python (stdlib only) | Weather app, fetches API key from Vault at runtime |
| Reverse Proxy | Nginx | Sole entry point, HTTP→HTTPS redirect |
| Monitoring | Prometheus + Node Exporter + Grafana | CPU & RAM dashboard |
| Dynamic DNS | cPanel API | Updates `exam.maximilianzimmer.com` to current Tailscale IP |

## Deployment

### Commands used: 1

```bash
sudo bash setup_exam.sh
```

The script prompts for credentials interactively (nothing stored in shell history):

```
Set up Tailscale + custom domain? [y/N]:

  # If yes:
  Tailscale auth key : <hidden>
  cPanel host        : <hidden>
  cPanel username    : <hidden>
  cPanel password    : <hidden>
```

### Or run directly from this repo on a fresh VM

```bash
curl -fsSL https://raw.githubusercontent.com/maximilianzimmer/exam-deploy/main/setup_exam.sh | sudo bash
```

## What the script does

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
| Application | `https://exam.maximilianzimmer.com` (Tailscale) or `https://<VM-IP>` |
| Grafana | `http://<VM-IP>:3000` — admin / admin |
| Prometheus | `http://<VM-IP>:9090` |
| Vault UI | `http://127.0.0.1:8200/ui` — internal only |

## Security notes

- Application source contains no secrets — API key is fetched from Vault at runtime
- Vault token is injected via `/etc/webapp.env` (mode 600, owned by `appuser`)
- `/metrics` endpoint is blocked at the Nginx level
- All credentials entered at setup time are `unset` immediately after being written to Vault
