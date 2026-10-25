# VPS Scripts

A collection of standalone installers for fresh Ubuntu VPS deployments. Each folder contains one purpose-built installer that can be downloaded directly from GitHub and run without cloning the repository.

## Included installers

| Folder | Purpose |
| --- | --- |
| `sni-proxy` | Install an Nginx SNI forwarding proxy on TCP port 443 |
| `ubuntu-dns-fix` | Repair broken VPS DNS and make the resolver settings persistent |
| `trading-stats-dashboard` | Install the Trading Stats Dashboard and its supporting services |

## Requirements

- Fresh or compatible Ubuntu VPS
- Root or sudo access
- Outbound access to GitHub and Ubuntu package repositories
- Public repository access for the unauthenticated raw GitHub commands

Read the notes for each installer before running it. These scripts change system packages, services, firewall rules and configuration files.

## SNI proxy

Installs `nginx-full` and configures Nginx stream routing. Incoming TLS connections on TCP port `443` are forwarded to the hostname supplied through the TLS SNI field.

The installer:

- Installs Nginx with stream support
- Creates `/etc/nginx/stream.conf`
- Enables SNI inspection with `ssl_preread`
- Adds the stream configuration to `nginx.conf`
- Validates the Nginx configuration
- Restarts Nginx
- Enables UFW
- Allows SSH and TCP port `443`
- Blocks UDP port `443` in both directions

Run:

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/vps-scripts/main/sni-proxy/install.sh | sudo bash
```

This is an unrestricted SNI forwarder. Anyone who can reach TCP port `443` on the VPS can attempt to use it. Restrict access at the provider firewall when the service is intended only for known clients.

Check it with:

```bash
sudo nginx -t
sudo systemctl status nginx --no-pager
sudo ufw status verbose
```

## Persistent Ubuntu DNS fix

Use this when the provider's DNS settings prevent a fresh Ubuntu VPS from resolving Ubuntu repositories or GitHub.

The bootstrap command first creates a temporary `/etc/resolv.conf` so the installer can be downloaded. The installer then:

- Enables `systemd-resolved`
- Configures Cloudflare and Google as primary resolvers
- Configures Quad9 and Cloudflare as fallback resolvers
- Replaces `/etc/resolv.conf` with the systemd-resolved symlink
- Tests resolution for Ubuntu package servers and GitHub
- Keeps the settings after reboot

Run:

```bash
sudo rm -f /etc/resolv.conf && printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee /etc/resolv.conf >/dev/null && { command -v curl >/dev/null 2>&1 || { sudo apt-get update -y && sudo apt-get install -y curl; }; } && curl -fsSL https://raw.githubusercontent.com/waqaarhussain/vps-scripts/main/ubuntu-dns-fix/install.sh -o /tmp/ubuntu-dns-fix.sh && sudo bash /tmp/ubuntu-dns-fix.sh
```

This changes DNS for the VPS itself. It does not configure DNS for WireGuard, IKEv2 or other VPN clients.

Check it with:

```bash
resolvectl status
getent hosts archive.ubuntu.com
getent hosts github.com
```

## Trading Stats Dashboard

Installs the Trading Stats Dashboard, its database, application service, Nginx configuration and local helper commands.

The installer asks for the dashboard secret through a hidden terminal prompt. The secret is written only to the VPS environment file and is not stored in this repository.

Run:

```bash
{ command -v curl >/dev/null 2>&1 || { sudo apt-get update -y && sudo apt-get install -y curl; }; } && curl -fsSL https://raw.githubusercontent.com/waqaarhussain/vps-scripts/main/trading-stats-dashboard/install.sh -o /tmp/trading-stats-dashboard-install.sh && sudo bash /tmp/trading-stats-dashboard-install.sh
```

When prompted, type the dashboard secret and press Enter. Nothing is displayed while the secret is being entered.

The installation includes the dashboard's local reset, week and month helpers.

## Repository layout

```text
vps-scripts/
├── sni-proxy/
│   └── install.sh
├── ubuntu-dns-fix/
│   └── install.sh
└── trading-stats-dashboard/
    └── install.sh
```

## Security

- No private keys, API tokens or proxy credentials should be committed here.
- The Trading Stats Dashboard secret is collected during installation.
- Review firewall changes before combining these installers with an existing server.
- Keep SSH access allowed before enabling or changing UFW.
- Use these installers only for systems you control.

## Public repository requirement

The repository must remain public for the unauthenticated `raw.githubusercontent.com` installation commands to work. Making it private would require authenticated GitHub downloads and the commands above would stop working.
