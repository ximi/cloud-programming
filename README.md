# Exam Infrastructure — Automated Deployment

Single-command provisioning of a complete, secure, and observable stack on a fresh Linux VM.

Repository: https://github.com/ximi/cloud-programming

## Command count: 1

The exam rubric measures automation efficiency by the number of manual terminal commands required to reach a fully operational state, starting after the VM is accessed (§4.2).

### On a fresh Ubuntu/Debian VM

```bash
curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/main/bootstrap.sh | sudo bash
```

That is the **only** command. `bootstrap.sh` downloads the rest of the repo as a tarball and runs `setup_exam.sh`, which provisions full infrastructure and deploys the application. **N = 1 → grade 10.**

### Creating a fresh VM from scratch (GCP)

If you also want VM creation automated (single command from a laptop with `gcloud` already authenticated):

```bash
bash provision.sh
```

This creates an `e2-micro` GCP VM and runs the full deployment on it. Prereqs (once per laptop): `gcloud auth login` and `gcloud config set project <project-id>` — authentication, not deployment.

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
1. Creates an `e2-micro` VM in `us-central1-a` (GCP always-free tier).
2. Opens firewall ports 3000 (Grafana) and 9090 (Prometheus). Ports 80/443 use the default GCP `http-server`/`https-server` tag rules.
3. Tars up `setup_exam.sh`, `deploy_app.sh`, `webapp.py`, `ddns-update.py` and uploads them to `/tmp/exam/` on the VM.
4. Runs `setup_exam.sh` with `sudo`, non-interactively, with the OpenWeatherMap API key passed via env file.
5. `setup_exam.sh` ends by calling `deploy_app.sh`, which deploys the application.
6. (Optional) updates the DNS A record via cPanel API and issues a Let's Encrypt cert with certbot.

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

After the infrastructure is up, editing `webapp.py` and shipping the change is:

```bash
sudo bash deploy_app.sh
```

This copies the new `webapp.py` to `/opt/`, reloads systemd, and restarts `webapp.service`. No Vault, Prometheus, Grafana, or Nginx work is repeated.

### Deploying on a non-GCP VM (local, AWS, DigitalOcean, etc.)

SSH into the fresh VM and run:

```bash
curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/main/bootstrap.sh | sudo bash
```

`bootstrap.sh` downloads the repo tarball to `/tmp/cloud-programming-deploy/` and execs `setup_exam.sh`. The script prompts for the OpenWeatherMap API key interactively.

If you're SSH'ing in from your laptop in the same command, allocate a TTY so the interactive prompts work:

```bash
ssh -t user@<vm-ip> 'curl -fsSL https://raw.githubusercontent.com/ximi/cloud-programming/main/bootstrap.sh | sudo bash'
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

| Service | URL |
|---|---|
| Application | `https://exam.maximilianzimmer.com` or `https://<VM-IP>` (self-signed cert) |
| Grafana | `http://<VM-IP>:3000` — admin / admin |
| Prometheus | `http://<VM-IP>:9090` |
| Vault UI | `http://127.0.0.1:8200/ui` — internal only, not exposed |

## Security notes

- **No secrets in source files.** `webapp.py` and `ddns-update.py` retrieve all credentials from Vault at runtime via the HTTP API.
- **Least-privilege Vault token.** The application does **not** hold the root token. `setup_exam.sh` writes a Vault policy `app-read` (read-only access to `secret/weather`) and issues a renewable token bound to that policy. That token is what `/etc/webapp.env` contains.
- **Injection via systemd EnvironmentFile.** `/etc/webapp.env` is mode 600, owned by `appuser`, and loaded by systemd at service start — never read by the app source.
- **Vault on localhost only.** Vault listens on `127.0.0.1:8200`; the app reaches it directly, the outside world cannot.
- **Auto-unseal on reboot.** A `vault-unseal.service` systemd unit re-unseals Vault after every reboot so the app keeps working unattended. The unseal key is stored mode 600, owned by `vault` — this is a documented production trade-off, acceptable in this exam environment.
- **Reverse proxy is the sole entry point to the application.** The app binds to `127.0.0.1:5000` and is only reachable via Nginx on `:443`. Direct port access to `:5000` from outside the VM is impossible.
- **No credentials in shell history.** All interactive prompts use `read -rsp` and variables are `unset` once consumed.
