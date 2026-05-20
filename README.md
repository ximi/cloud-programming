# Exam Infrastructure — Automated Deployment

Single-command provisioning of a complete, secure, and observable stack on a fresh Linux VM.

Repository: https://github.com/ximi/cloud-programming

## Command count: 1

The exam rubric measures automation efficiency by the number of manual terminal commands required to reach a fully operational state, starting after the VM is accessed (§4.2).

### On a fresh Ubuntu/Debian VM

```bash
curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/bootstrap.sh | sudo bash
```

That is the **only** command. `bootstrap.sh` downloads the rest of the repo as a tarball and runs `setup_exam.sh`, which provisions full infrastructure and deploys the application. **N = 1 → grade 10.**

### Creating a fresh VM from scratch (GCP)

If you also want VM creation automated, run this on any laptop with `gcloud` authenticated — no local repo clone required:

```bash
curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/provision.sh | bash
```

This creates an `e2-micro` GCP VM (with the default `http-server`/`https-server` tags so :80 and :443 are open), then triggers `bootstrap.sh` on the VM, which pulls everything from GitHub and runs `setup_exam.sh`. Single command, single source of truth.

Prereqs once per laptop: `gcloud auth login` and `gcloud config set project <project-id>` — authentication, not deployment.

## Stack

| Component | Tool | Purpose |
|---|---|---|
| Secret management | HashiCorp Vault | Stores API keys; the app reads them at runtime via the Vault HTTP API |
| Application | Python (stdlib only) | Weather app — fetches the OpenWeatherMap API key from Vault on every request |
| Reverse proxy | Nginx | Sole entry point to the app; `:80` redirects to `:443`, TLS terminated here |
| Monitoring | Prometheus + Node Exporter + Grafana | Real-time CPU and RAM dashboard (5s refresh) |
| Dynamic DNS | cPanel API (optional) | Updates `exam.maximilianzimmer.com` to the VM's public IP |

## Deployment processes

The repo separates two distinct automated processes, in line with the exam clarification ("design a simple deployment process [for the app]… automate the deployment of the infrastructure as well"):

| Process | Script | Runs |
|---|---|---|
| Infrastructure provisioning | `setup_exam.sh` | Once per VM: installs Vault, Prometheus, Grafana, Node Exporter, Nginx; writes systemd units; creates the Vault `app-read` policy and a least-privilege token |
| Application deployment | `deploy_app.sh` | Whenever `webapp.py` changes: installs the new code to `/opt/webapp.py` and restarts `webapp.service` |

`provision.sh` orchestrates both for the first-time setup on a freshly created VM. After the initial deployment, the operator only ever needs `deploy_app.sh` for app updates — the infrastructure is untouched.

### Initial deployment (one command)

```bash
bash provision.sh
```

What happens, in order:
1. Creates an `e2-micro` VM in `us-central1-a` (GCP always-free tier). Only :80 and :443 are open externally (via the default `http-server`/`https-server` tags); Grafana and Prometheus are reached through Nginx, not their own ports.
2. SSHes in and writes a temporary env file containing the OpenWeatherMap API key and the resolved external host (the custom domain if configured, otherwise the VM's public IP).
3. Curl-pipes `bootstrap.sh` on the VM, which downloads the rest of the repo and runs `setup_exam.sh` with `sudo --preserve-env`.
4. `setup_exam.sh` initialises Vault, **prints the unseal key once** (it is not stored on disk — see the reboot note below), provisions Prometheus, Grafana, Nginx, and the systemd units, then calls `deploy_app.sh`.
5. (Optional) updates the DNS A record via cPanel API and issues a Let's Encrypt cert with certbot.

The provisioner prompts for everything upfront, then runs unattended:

```
  OpenWeatherMap API key: <hidden>
  Configure custom domain (exam.maximilianzimmer.com)? [y/N]:

  # If yes:
  cPanel host     : <hidden>
  cPanel username : <hidden>
  cPanel password : <hidden>
  Email (certbot) : <hidden>
```

### Application updates (one command, after initial deployment)

After the infrastructure is up, shipping a new version of the app is:

```bash
sudo bash deploy_app.sh
```

By default this pulls the latest `webapp.py` from `https://raw.githubusercontent.com/ximi/cloud-programming/master/webapp.py`, installs it at `/opt/webapp.py`, and restarts `webapp.service`. No Vault, Prometheus, Grafana, or Nginx work is repeated.

In a real-world setup the application would live in its own repo. Override the source with either:

```bash
sudo WEBAPP_URL=https://raw.githubusercontent.com/me/my-app/main/webapp.py bash deploy_app.sh
sudo WEBAPP_FILE=./webapp.py bash deploy_app.sh           # install a local file (for testing before push)
```

The initial deploy invoked by `setup_exam.sh` uses the bundled tarball copy via `WEBAPP_FILE=…`, so first-time provisioning doesn't need a second round-trip to GitHub.

### Deploying on a non-GCP VM (local, AWS, DigitalOcean, etc.)

SSH into the fresh VM and run:

```bash
curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/bootstrap.sh | sudo bash
```

`bootstrap.sh` downloads the repo tarball to `/tmp/cloud-programming-deploy/` and execs `setup_exam.sh`. The script prompts for the OpenWeatherMap API key interactively.

If you're SSH'ing in from your laptop in the same command, allocate a TTY so the interactive prompts work:

```bash
ssh -t user@<vm-ip> 'curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/master/bootstrap.sh | sudo bash'
```

Still **1 command** after VM access.

## File layout

```
bootstrap.sh        One-command entry point. Downloads the rest of the repo and runs setup_exam.sh.
provision.sh        GCP-specific orchestrator: creates a fresh e2-micro VM and runs setup on it.
setup_exam.sh       Infrastructure provisioning: packages, Vault, monitoring, Nginx, systemd units.
deploy_app.sh       Application deployment: installs webapp.py and restarts the service.
webapp.py           The Flask-free Python webapp that reads its API key from Vault at runtime.
ddns-update.py      Optional: pulls cPanel creds from Vault and updates the DNS A record.
REVIEW.md           Code review notes (development artefact — can be ignored by graders).
```

## Access

All HTTP traffic enters the VM through Nginx on `:443`. Grafana and Prometheus are served as sub-paths of the same hostname, not on their own ports.

| Service | URL |
|---|---|
| Application | `https://<host>` |
| Grafana | `https://<host>/grafana/` — user `admin`, password printed at the end of setup |
| Prometheus | `https://<host>/prometheus/` |
| Vault UI | `http://127.0.0.1:8200/ui` — bound to localhost, not exposed externally |

`<host>` is whatever the operator chose: the custom domain (if configured) or the VM's public IP. The cert SAN matches that host.

The Grafana password is rotated off the default `admin/admin` during setup and stored in Vault at `secret/grafana`. To retrieve it after the fact (Vault must be unsealed):

```bash
VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<a-token-with-read-on-secret/grafana> \
    vault kv get secret/grafana
```

## After a reboot — unseal Vault

The unseal key is **not** stored on disk. After any reboot you need to bring Vault (and therefore the webapp) back online:

```bash
sudo /opt/unseal-vault.sh
```

The helper prompts for the unseal key, runs `vault operator unseal`, and restarts `webapp.service`. The key was printed once at the end of `setup_exam.sh` — save it somewhere safe.

## Security notes

- **No secrets in source files.** `webapp.py` and `ddns-update.py` retrieve all credentials from Vault at runtime via the HTTP API.
- **Least-privilege Vault tokens.** The application does **not** hold the root token. `setup_exam.sh` writes:
  - an `app-read` policy (read-only on `secret/weather`) and issues a renewable token for the webapp
  - a `ddns-read` policy (read-only on `secret/cpanel`) and issues a separate token for the DDNS updater
  
  The root token only lives in shell memory during setup and is never persisted.
- **Unseal key is never written to disk.** It is shown once at setup, then the operator's responsibility. Re-unseal after reboot via `sudo /opt/unseal-vault.sh`.
- **Grafana admin password is rotated.** The default `admin/admin` is changed during provisioning to a 24-char random string, written to Vault at `secret/grafana`, and printed once in the setup summary.
- **Injection via systemd EnvironmentFile.** `/etc/webapp.env` is mode 600, owned by `appuser`, loaded by systemd at service start — never read by the app source.
- **Vault on localhost only.** Vault listens on `127.0.0.1:8200`; the app reaches it directly, the outside world cannot.
- **Nginx is the sole entry point.** The app binds to `127.0.0.1:5000`, Grafana to `127.0.0.1:3000`, Prometheus to `127.0.0.1:9090`. All three are reachable only via Nginx on `:443`. The only ports open to the internet are `:80` (redirect → `:443`) and `:443`.
- **No credentials in shell history.** All interactive prompts use `read -rsp` and variables are `unset` once consumed.
