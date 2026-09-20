# VPS Scripts

Reusable install scripts for fresh Ubuntu VPS deployments.

## SNI proxy

Installs and configures Nginx stream proxying with SNI routing, applies the supplied UFW rules, validates Nginx, and restarts it.

```bash
curl -fsSL https://raw.githubusercontent.com/waqaarhussain/vps-scripts/main/sni-proxy/install.sh | sudo bash
```

The repository must remain public for the unauthenticated one-line command above to work.
