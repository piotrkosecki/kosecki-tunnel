# kosecki-tunnel

Replaces the [ngrok](https://ngrok.com) tunnel for `*.kosecki.dev` with a
self-hosted reverse tunnel:

```
Internet  →  *.kosecki.dev (Cloudflare A → static IP)
          ↓
         GCE VM europe-central2  (e2-micro Debian 12, static IP)
          ↓ :443            Caddy, auto-TLS via Let's Encrypt HTTP-01
          ↓ :8080           localhost socket held open by SSH reverse tunnel
            ↑
          autossh (@localhost)  →  pk@<VM>:22 (reverse 8080→127.0.0.1:3080)
            ↑
         local 127.0.0.1:3080   (existing ngrok-gateway, unchanged)
            ↓ routes
           upstream services (18086/18087/18088/18090, model/v1)
```

That's it. Six services, one VM, no ngrok.

## Quickstart

```bash
# 1. Bring up the VM (idempotent). Prints the static IP at the end.
bash infra/create-vm.sh

# 2. Inside the VM: install Caddy + harden sshd. Run via gcloud compute ssh.
gcloud compute ssh pk@kosecki-tunnel-vm --command 'sudo bash /tmp/setup-vm.sh'
# You'll need to scp setup-vm.sh first; or use gcloud compute scp:
gcloud compute scp infra/setup-vm.sh kosecki-tunnel-vm:/tmp/
gcloud compute ssh pk@kosecki-tunnel-vm --command 'sudo bash /tmp/setup-vm.sh'

# 3. Point DNS at the static IP (either path works).
CF_API_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxx bash dns/setup-cloudflare.sh <STATIC_IP>
# or manually — see dns/setup-dns-manual.md

# 4. Start the reverse tunnel locally (one-time, persists across reboots).
sudo install -m 0755 /usr/bin/autossh /usr/bin/autossh 2>/dev/null || sudo apt-get install -y autossh
# Edit tunnel/autossh-tunnel.service — replace KOSECKI_TUNNEL_HOST with the VM's IP or hostname
sudo cp tunnel/autossh-tunnel.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now autossh-tunnel.service

# 5. Verify
curl -I https://kosecki.dev/
curl -I https://q4.kosecki.dev/q4/
```

## Why this layout

The existing `ngrok-gateway` (`~/ngrok-gateway/gateway.py`, port 3080) is left
intact — it's the smart routing layer with `auth: true` for `/model/v1`,
long-poll-friendly timeouts on `/q3 /q4 /q2 /quake-mp`, and across-the-board
cache headers. We only swap the *outside-the-house* tunnel layer.

| Layer        | Old (ngrok)        | New (this repo)              |
| ------------ | ------------------ | ---------------------------- |
| Tunnel agent | `ngrok http` to ngrok.com | `autossh -R 8080:...` reverse SSH |
| Public entry | ngrok reserved domain `kosecki.ngrok.dev` (TLS by ngrok) | `*.kosecki.dev` A → static IP, Caddy auto-TLS |
| Backend      | ngrok-gateway :3080    | ngrok-gateway :3080 (same) |
| DNS          | ngrok (CNAME)     | Cloudflare A records         |

## Why e2-micro + Debian 12

- e2-micro is free tier in europe-central2 (subject to GCE free-tier limits —
  confirm in console)
- Static external IP is ~$3/mo regardless of VM size — that's the bulk of the
  bill
- Debian 12 (bookworm) has Caddy available from Cloudsmith official repo —
  apt-get installable, no snap

## Cost

- Static IP:    ~$3.00/month
- e2-micro:     free tier (or ~$0.50/month if you consistently exceed free
                tier limits; first-time credits often cover it)
- Out egress:   first 1 GB/month free, ~$0.12/GB after. With the routes we
                expose, expect under 1 GB/mo comfortably
- Estimated total: **a few dollars/month**. Wire up a billing budget alert at
  https://console.cloud.google.com/billing/budgets (e.g. $5/mo with 50% trigger
  to email you) to be safe.

## DNS plan

Two A records, both `proxied: false`:

- `kosecki.dev`     → static IP
- `*.kosecki.dev`   → static IP

Cloudflare *proxy* mode would intercept the request and require an Origin
Certificate on Caddy. The token-plus-API-token path is fine (`dns/setup-cloudflare.sh`)
but we deliberately use the DNS-only shortcut because:

1. The `.dev` HSTS preload list requires HTTPS everywhere; Let's Encrypt
   HTTP-01 works directly against the VM, which is the path of least
   surprise.
2. Caddy auto-renews the cert. No Certbot cron, no cron at all.
3. We get full `X-Real-IP` / `X-Forwarded-For` from the *original* client
   (because there's no CDN in front).

If you ever want Cloudflare proxy back on:

- In the CF dashboard set SSL/TLS mode to **Full (strict)**
- Issue an Origin Certificate and serve it from Caddy
- Update `*.kosecki.dev` → orange cloud

## Operating

```bash
# Tunnel process
sudo systemctl status autossh-tunnel.service
sudo journalctl -u autossh-tunnel.service -n 50 --no-pager

# VM
gcloud compute ssh pk@kosecki-tunnel-vm --command 'sudo caddy status && sudo caddy reload --config /etc/caddy/Caddyfile'
gcloud compute ssh pk@kosecki-tunnel-vm --command 'sudo journalctl -u caddy -n 50 --no-pager'

# Restart the VM (cheap, tunnel auto-reconnects in < 10 s)
gcloud compute instances stop kosecki-tunnel-vm --zone europe-central2-a
gcloud compute instances start kosecki-tunnel-vm --zone europe-central2-a
```

## Tear-down

```bash
gcloud compute instances delete  kosecki-tunnel-vm --zone europe-central2-a
gcloud compute addresses delete  kosecki-dev-ip    --region europe-central2
gcloud compute firewall-rules delete kosecki-dev-web
gcloud compute firewall-rules delete kosecki-dev-ssh
sudo systemctl disable --now autossh-tunnel.service
# Cloudflare: delete the two A records you added (or via CF API)
```
