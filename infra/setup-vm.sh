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
# Idempotent: skip the gpg/debian repo setup if Caddy is already installed,
# and skip the apt install if the package is already at its current version.
if ! command -v caddy >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https curl ca-certificates gnupg
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian bookworm main" \
        > /etc/apt/sources.list.d/caddy.list
    apt-get update -qq
    apt-get install -y --no-install-recommends caddy
else
    echo "(caddy already installed: $(caddy version))"
fi

echo "── writing /etc/caddy/Caddyfile ──"
cat > /etc/caddy/Caddyfile <<'CADDY_EOF'
# Caddy reverse proxy: SAN list (kosecki.dev + every used subdomain)
#   -> 127.0.0.1:TUNNEL_PORT (autossh reverse tunnel from local)
#
# TLS is auto-issued by Let's Encrypt via HTTP-01; Cloudflare proxy mode MUST
# be OFF (gray cloud) for this to succeed. .dev is on the HSTS preload list,
# so HTTP->HTTPS redirects are mandatory and free.
#
# Why SAN list not wildcard?
#   Wildcard certs (*.kosecki.dev) require DNS-01 challenge, which needs
#   either a Caddy DNS plugin (xcaddy build + Cloudflare API token) or a
#   custom solver. SAN list with HTTP-01 needs neither — just :80 reachable.
#   Cost: when adding a new subdomain, append it to the hosts list below
#   and re-run setup-vm.sh.
#
# Note: Caddy's reverse_proxy already forwards X-Forwarded-For / -Proto /
# X-Real-IP to the upstream automatically — no need to spell them out.

__HOSTS__ {
    reverse_proxy 127.0.0.1:__TUNNEL_PORT__ {
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

    # Cache control for long-poll endpoints. Block form sets the header
    # on every response (root-level directive in Caddy v2).
    header {
        Cache-Control "no-cache, no-store, must-revalidate"
        Pragma "no-cache"
        Expires "0"
    }
}
CADDY_EOF

# Generate the list of subject-alt-names from the current ngrok-gateway routes.
# Wildcard replaced by explicit apex + every host actually used, so a single
# HTTP-01 cert covers them all (no DNS plugin / CF token needed).
HOSTS_FROM_ROUTES=(
    "kosecki.dev"
    "tetris.kosecki.dev"
    "chat.kosecki.dev"
    "quake.kosecki.dev"
    "q2.kosecki.dev"
    "q3.kosecki.dev"
    "q4.kosecki.dev"
    "quake-mp.kosecki.dev"
    "model.kosecki.dev"
)
# Caddy wants site addresses comma-space separated, e.g. "host1, host2, host3".
HOSTS_CSV=$(printf '%s, ' "${HOSTS_FROM_ROUTES[@]}")
HOSTS_CSV="${HOSTS_CSV%, }"  # strip trailing ", "
# Replace the placeholder marker with the explicit host list, and TUNNEL_PORT too.
sed -i "s|__HOSTS__|${HOSTS_CSV}|" /etc/caddy/Caddyfile
sed -i "s|__TUNNEL_PORT__|${TUNNEL_PORT}|" /etc/caddy/Caddyfile

echo "── final Caddyfile ──"
cat /etc/caddy/Caddyfile

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
