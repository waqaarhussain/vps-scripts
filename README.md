# VPS Scripts

Reusable install scripts for fresh Ubuntu VPS deployments.

## SNI proxy

Installs and configures Nginx stream proxying with SNI routing, applies the supplied UFW rules, validates Nginx, and restarts it.

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/vps-scripts/main/sni-proxy/install.sh | sudo bash
```

## Persistent Ubuntu DNS fix

Temporarily restores DNS so GitHub and Ubuntu package servers can be reached, then configures `systemd-resolved` with persistent DNS servers that survive reboots.

```bash
sudo rm -f /etc/resolv.conf && printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee /etc/resolv.conf >/dev/null && { command -v curl >/dev/null 2>&1 || { sudo apt-get update -y && sudo apt-get install -y curl; }; } && curl -fsSL https://raw.githubusercontent.com/waqaarhussain/vps-scripts/main/ubuntu-dns-fix/install.sh -o /tmp/ubuntu-dns-fix.sh && sudo bash /tmp/ubuntu-dns-fix.sh
```

The repository must remain public for these unauthenticated installation commands to work.
