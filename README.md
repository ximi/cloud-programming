# Infrastructure — Automated Deployment

Single-command provisioning of a complete, secure, and observable stack on a fresh Linux VM.

A reverse-proxied web application with secret management, real-time monitoring, and automated TLS — deployed end-to-end from one command, on bare-metal or in the cloud.

Repository: https://github.com/ximi/cloud-programming

## Quickstart

On a fresh Ubuntu/Debian VM:

```bash
curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/bootstrap.sh | sudo bash
```

`bootstrap.sh` downloads the repository tarball and runs `setup.sh`, which installs and configures Vault, Prometheus, Grafana, Node Exporter, Nginx, and the application, in that order. The whole thing takes about three minutes on a stock e2-micro.

To also automate VM creation on GCP, run this from any laptop with `gcloud` authenticated:

```bash
curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/provision.sh | bash
```

It creates an `e2-micro` (with the default `http-server`/`https-server` tags so :80 and :443 are open), then triggers the same bootstrap on the new VM over SSH. One-time prerequisites: `gcloud auth login` and `gcloud config set project <project-id>`.

## Stack

| Component | Tool | Purpose |
|---|---|---|
| Secret management | HashiCorp Vault | Stores API keys and credentials; the app reads them at runtime via the Vault HTTP API |
| Application | Python (stdlib only) | Weather app — fetches the OpenWeatherMap API key from Vault on every request |
| Reverse proxy | Nginx | Sole entry point; `:80` redirects to `:443`, TLS terminated here |
| Monitoring | Prometheus + Node Exporter + Grafana | Real-time CPU and RAM dashboard (5s refresh) |
| Dynamic DNS / TLS | cPanel API + certbot DNS-01 | Optional: keeps a custom domain pointed at the VM and issues a Let's Encrypt cert |

## Deployment processes

Infrastructure provisioning and application deployment are kept as separate scripts so day-to-day app updates don't reach into Vault, Prometheus, Grafana, or Nginx:

| Script | Runs |
|---|---|
| `setup.sh` | Once per VM. Installs packages, configures Vault (initialise, print unseal key, write `app-read` and `ddns-read` policies, issue least-privilege tokens), writes systemd units for Prometheus/Node Exporter/Grafana, generates the TLS cert (self-signed or LE), configures Nginx as the sole entry point, then hands off to `deploy_app.sh` for the initial app install. |
| `deploy_app.sh` | Every time the app needs to ship. Fetches the latest `webapp.py` from a configurable URL (defaults to this repo, but easy to point at a separate application repo), installs it at `/opt/webapp.py`, restarts `webapp.service`. |

`provision.sh` orchestrates both for the first-time setup on a freshly created GCP VM.

### Initial deployment

```bash
bash provision.sh
```

The provisioner prompts for everything upfront, then runs unattended:

```
  OpenWeatherMap API key   : <hidden>
  Configure custom domain? : [y/N]
  # if yes:
  cPanel host              : <hidden>
  cPanel username          : <hidden>
  cPanel password          : <hidden>
  Email (Let's Encrypt)    : <hidden>
```

What happens, in order:

1. Creates an `e2-micro` in `us-central1-a` (GCP always-free tier). Only :80 and :443 are open externally; Grafana and Prometheus are reached through Nginx on the same port, not on their own.
2. SSHes in and writes a temporary env file containing the OpenWeatherMap key and the resolved external host (the domain if configured, otherwise the VM's public IP).
3. Curl-pipes `bootstrap.sh` on the VM, which downloads the rest of the repo and runs `setup.sh` with `sudo --preserve-env`.
4. `setup.sh` initialises Vault, **prints the unseal key once** (not stored on disk — see "After a reboot" below), provisions Prometheus, Grafana, Nginx, and the systemd units, then calls `deploy_app.sh` to install the application.
5. On the domain path, updates the DNS A record via cPanel and issues a Let's Encrypt cert with certbot.

### Application updates

After the infrastructure is up, shipping a new version of the app is a single command:

```bash
sudo bash deploy_app.sh
```

By default this pulls the latest `webapp.py` from `https://raw.githubusercontent.com/ximi/cloud-programming/master/webapp.py`, installs it at `/opt/webapp.py`, and restarts `webapp.service`. Vault, Prometheus, Grafana, and Nginx are untouched.

In a real-world setup the application would live in its own repo. Override the source with either:

```bash
sudo WEBAPP_URL=https://raw.githubusercontent.com/me/my-app/main/webapp.py bash deploy_app.sh
sudo WEBAPP_FILE=./webapp.py bash deploy_app.sh    # local file (testing before push)
```

The initial deploy invoked by `setup.sh` uses the bundled tarball copy via `WEBAPP_FILE=…`, so first-time provisioning doesn't need a second round-trip to GitHub.

### Deploying on a non-GCP VM (bare metal, AWS, DigitalOcean, etc.)

SSH into the fresh VM and run:

```bash
curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/bootstrap.sh | sudo bash
```

If you're invoking that over a single non-interactive SSH command, allocate a TTY so the prompts work:

```bash
ssh -t user@<vm-ip> 'curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/bootstrap.sh | sudo bash'
```

For a local/NAT'd VM where you want a custom domain reachable from anywhere without port-forwarding, the Tailscale path (see below) wires up TLS automatically too.

## Access

All HTTP traffic enters the VM through Nginx on `:443`. Grafana and Prometheus are served as sub-paths of the same hostname, not on their own ports.

| Service | URL |
|---|---|
| Application | `https://<host>` |
| Grafana | `https://<host>/grafana/` — user `admin`, password printed at the end of setup |
| Prometheus | `https://<host>/prometheus/` |
| Vault UI | `http://127.0.0.1:8200/ui` — bound to localhost, not exposed externally |

`<host>` is whatever the operator chose: a custom domain (if configured) or the VM's public IP. The cert SAN matches that host.

The Grafana password is rotated off the default `admin/admin` during setup and stored in Vault at `secret/grafana`. To retrieve it later (Vault must be unsealed):

```bash
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<token-with-read-on-secret/grafana> \
    vault kv get secret/grafana
```

## TLS

Three configurations, picked automatically based on what the operator provides:

| Path | Cert source | When it's used |
|---|---|---|
| Direct public IP (no domain) | Self-signed, SAN matches the IP | Default for any VM without a configured custom domain |
| Custom domain on a public-reachable host (e.g. GCP with a public A record) | Let's Encrypt via HTTP-01 (`certbot --nginx`) | `provision.sh` flow when a domain is supplied |
| Custom domain on Tailscale (CGNAT 100.x.x.x, not publicly routable) | Let's Encrypt via DNS-01 (`certbot --manual` + a cPanel TXT hook) | `setup.sh` Tailscale path when LE email and cPanel credentials are supplied |

HTTP-01 doesn't work on the Tailscale path because LE's validator can't reach a 100.x.x.x address from the public internet — DNS-01 sidesteps that by proving control through a TXT record on the public zone. The hook (`cpanel-dns-hook.py`) reads cPanel credentials from Vault using the same `ddns-read` token the DDNS updater uses, and is invoked by certbot for both the `auth` (create TXT) and `cleanup` (delete TXT) phases.

The cert is valid 90 days; certbot's auto-renewal timer (installed by the apt package) re-runs the hooks on schedule, provided Vault is unsealed at renewal time.

## After a reboot — unseal Vault

The unseal key is **not** stored on disk. After any reboot, Vault must be unsealed before the webapp (or the DDNS/certbot renewal hooks) can read their secrets:

```bash
sudo /opt/unseal-vault.sh
```

The helper prompts for the unseal key, runs `vault operator unseal`, and restarts `webapp.service`. The key was printed once at the end of `setup.sh` — save it somewhere safe (e.g. a password manager).

## File layout

```
bootstrap.sh         One-command entry point. Downloads the rest of the repo and runs setup.sh.
provision.sh         GCP orchestrator: creates a fresh e2-micro VM and runs setup on it.
setup.sh        Infrastructure provisioning: packages, Vault, monitoring, Nginx, systemd units.
deploy_app.sh        Application deployment: fetches webapp.py from a URL and restarts the service.
webapp.py            The Flask-free Python webapp that reads its API key from Vault at runtime.
ddns-update.py       Pulls cPanel creds from Vault and updates the DNS A record (Tailscale path).
cpanel-dns-hook.py   certbot DNS-01 hook for cPanel — used to issue/renew the LE cert on Tailscale.
```

## Security notes

- **No secrets in source files.** `webapp.py`, `ddns-update.py`, and `cpanel-dns-hook.py` retrieve all credentials from Vault at runtime via the HTTP API.
- **Least-privilege Vault tokens.** The application does **not** hold the root token. `setup.sh` writes:
  - an `app-read` policy (read-only on `secret/weather`) and issues a renewable token for the webapp
  - a `ddns-read` policy (read-only on `secret/cpanel`) and issues a separate token for the DDNS updater and the certbot DNS hook

  The root token only lives in shell memory during setup and is never persisted.
- **Unseal key is never written to disk.** It is shown once at setup; the operator is responsible for storing it. Re-unseal after reboot via `sudo /opt/unseal-vault.sh`.
- **Grafana admin password is rotated.** The default `admin/admin` is changed during provisioning to a 24-character random string, written to Vault at `secret/grafana`, and printed once in the setup summary.
- **Injection via systemd `EnvironmentFile`.** `/etc/webapp.env` is mode 600, owned by `appuser`, loaded by systemd at service start — never read by the app source.
- **Vault on localhost only.** Vault listens on `127.0.0.1:8200`; the app reaches it directly, the outside world cannot.
- **Nginx is the sole entry point.** The app binds to `127.0.0.1:5000`, Grafana to `127.0.0.1:3000`, Prometheus to `127.0.0.1:9090`. All three are reachable only via Nginx on `:443`. The only ports open to the internet are `:80` (redirect → `:443`) and `:443`.
- **No credentials in shell history.** All interactive prompts use `read -rsp` (silent) and variables are `unset` once consumed. See also the longer notes on what is and isn't exposed elsewhere on the VM (process listings during Vault CLI calls, terminal scrollback for printed secrets) — these are documented trade-offs, not history leaks.
