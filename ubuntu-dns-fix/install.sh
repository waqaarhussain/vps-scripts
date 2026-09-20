#!/usr/bin/env bash
set -euo pipefail

mkdir -p /etc/systemd/resolved.conf.d

cat >/etc/systemd/resolved.conf.d/99-app-dns.conf <<'CONF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 1.0.0.1
DNSStubListener=yes
CONF

systemctl enable systemd-resolved >/dev/null 2>&1 || true
systemctl restart systemd-resolved

if [ -L /etc/resolv.conf ] || [ -e /etc/resolv.conf ]; then
  rm -f /etc/resolv.conf
fi
ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

echo
echo "DNS set for the VPS itself."
echo "This affects apt/curl/package downloads only."
echo "It does NOT add DNS to WireGuard clients."
echo

echo "Testing resolution..."
getent hosts archive.ubuntu.com
getent hosts github.com

echo
echo "DONE"
