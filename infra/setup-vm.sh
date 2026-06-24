#!/usr/bin/env bash
# setup-vm.sh — runs INSIDE the VM. Installs Caddy, writes the Caddyfile,
# hardened sshd config (key-only), enables and starts the service.
#
# Domain substitution: the placeholder @@KOSECKI_DOMAIN@@ is replaced before
# this script is uploaded if you pipe it through envsubst; otherwise the
# Caddyfile uses an explicit default of "kosecki.dev". Override with:
#   KOSECKI_DOMAIN=example.dev sudo bash /tmp/setup-vm.sh

set -euo pipefail

DOMAIN="${KOSECKI_DOMAIN:-kosecki.dev}"
TUNNEL_PORT="${TUNNEL_PORT:-8080}"

echo "── installing Caddy from official repo ──"
apt-get update -qq
apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https curl ca-certificates gnupg
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian bookworm main" \
    > /etc/apt/sources.list.d/caddy.list
apt-get update -qq
apt-get install -y --no-install-recommends caddy

echo "── writing /etc/caddy/Caddyfile ──"
cat > /etc/caddy/Caddyfile <<EOF
# Caddy reverse proxy: *.kosecki.dev -> 127.0.0.1:${TUNNEL_PORT} (autossh reverse tunnel)
# TLS is auto-issued by Let's Encrypt via HTTP-01; Cloudflare proxy mode
# MUST be OFF (gray cloud) for this to succeed. .dev is on the HSTS preload
# list, so HTTP->HTTPS redirects are mandatory and free.

*.${DOMAIN}, ${DOMAIN} {
    reverse_proxy 127.0.0.1:${TUNNEL_PORT} {
        # game/chat sockets stay open for tens of seconds; let them through
        flush_interval -1
        transport http {
            dial_timeout 5s
            response_header_timeout 600s
            read_timeout 600s
            write_timeout 600s
        }
    }

    encode zstd gzip

    # pass original client IP through to the upstream gateway
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}

    # long-poll states it's healthy
    header_down Cache-Control "no-cache, no-store, must-revalidate"
}

import /etc/caddy/sites/*.caddy
EOF
mkdir -p /etc/caddy/sites
: > /etc/caddy/sites/.keep

echo "── hardening sshd (key-only auth) ──"
SSHD="/etc/ssh/sshd_config"
cp "$SSHD" "${SSHD}.bak.$(date +%Y%m%d-%H%M%S)"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD"
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD"
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD"
sed -i 's/^#\?UsePAM.*/UsePAM yes/' "$SSHD"
systemctl restart ssh

echo "── enabling + starting Caddy ──"
systemctl enable caddy
systemctl restart caddy

echo
echo "── verification ──"
systemctl is-active caddy && echo "caddy: active"
ss -tnlp | grep -E ':(80|443)\b' || true
echo
echo "Caddy will issue the Let's Encrypt cert on first request (HTTP-01 on :80)."
echo "Make sure DNS for *.$DOMAIN points to this VM's external IP AND the"
echo "Cloudflare proxy is OFF (gray cloud), then test:"
echo "  curl -I https://$DOMAIN/"
echo "  curl -I https://q4.$DOMAIN/q4/"
