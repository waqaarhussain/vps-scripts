#!/usr/bin/env bash
set -e

apt update -y && apt install -y nginx-full

cat > /etc/nginx/stream.conf <<'EOF'
stream {
    ssl_preread on;

    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    server {
        listen 443 reuseport;
        proxy_connect_timeout 10s;
        proxy_timeout 300s;

        proxy_pass $ssl_preread_server_name:443;
    }
}
EOF

grep -qE "^\s*include\s+/etc/nginx/stream\.conf;" /etc/nginx/nginx.conf || sed -i "/^http {/i include /etc/nginx/stream.conf;\n" /etc/nginx/nginx.conf

nginx -t
systemctl restart nginx

ufw --force enable
ufw deny out 443/udp
ufw deny in 443/udp
ufw allow ssh
ufw allow 443/tcp
