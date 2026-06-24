#!/usr/bin/env bash
# create-vm.sh — provisions the kosecki.dev tunnel VM.
#
# Idempotent. Re-running is safe; existing resources are skipped.
# After it finishes, run infra/setup-vm.sh on the VM (the script prints the
# gcloud command to do so), then point DNS at the static IP printed at the end.
#
# Resources created (all tagged/labeled purpose=kosecki-tunnel):
#   - Static external IP:  kosecki-dev-ip    (region europe-central2)
#   - Firewall rule:       kosecki-dev-web   (tcp:80, tcp:443 from 0.0.0.0/0)
#   - Firewall rule:       kosecki-dev-ssh   (tcp:22 from 0.0.0.0/0, key-only auth)
#   - VM:                  kosecki-tunnel-vm (e2-micro, Debian 12, europe-central2-a)
#
# Requires: gcloud CLI authenticated, project set active, ssh key at
# ~/.ssh/id_ed25519 (override with $SSH_PUBKEY_FILE).

set -euo pipefail

PROJECT="${PROJECT:-$(gcloud config get-value project)}"
REGION="europe-central2"
ZONE="europe-central2-a"
VM_NAME="kosecki-tunnel-vm"
IP_NAME="kosecki-dev-ip"
WEB_FW="kosecki-dev-web"
SSH_FW="kosecki-dev-ssh"
MACHINE="e2-micro"
TAGS="http-server,https-server"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

die() { echo "ERROR: $*" >&2; exit 1; }
section() { echo; echo "── $* ──"; }

[[ -r "$SSH_PUBKEY_FILE" ]] || die "Cannot read SSH public key at $SSH_PUBKEY_FILE. Set SSH_PUBKEY_FILE to override."

gcloud --project "$PROJECT" config set compute/region "$REGION" >/dev/null
gcloud --project "$PROJECT" config set compute/zone "$ZONE" >/dev/null
gcloud --project "$PROJECT" config set core/disable_prompts true >/dev/null

# Make gcloud compute ssh use this machine's id_ed25519 by adding a host block.
# gcloud doesn't ship a clean config knob for "use my existing key, not the
# generated google_compute_engine one" — we just write to ~/.ssh/config.
SSH_CONFIG="$HOME/.ssh/config"
SSH_CONFIG_BLOCK="\
# --- kosecki-tunnel (added by infra/create-vm.sh) ---
Host $VM_NAME *.${ZONE}.*.compute.google.com *.compute.google.com
    IdentityFile $HOME/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
"
if [[ -f "$SSH_CONFIG" ]] && grep -qF 'kosecki-tunnel (added by infra/create-vm.sh)' "$SSH_CONFIG"; then
    echo "(ssh config block already present, skipping)"
else
    printf '\n%s\n' "$SSH_CONFIG_BLOCK" >> "$SSH_CONFIG"
    chmod 0600 "$SSH_CONFIG"
    echo "wrote SSH config block to $SSH_CONFIG"
fi

section "Static external IP ($IP_NAME)"
if ! gcloud --project "$PROJECT" compute addresses describe "$IP_NAME" --region "$REGION" >/dev/null 2>&1; then
  gcloud --project "$PROJECT" compute addresses create "$IP_NAME" \
      --region "$REGION" \
      --description "Static IP for kosecki.dev tunnel VM"
else
  echo "(already exists, skipping)"
fi
STATIC_IP="$(gcloud --project "$PROJECT" compute addresses describe "$IP_NAME" --region "$REGION" --format='value(address)')"
echo "static IP: $STATIC_IP"

section "Firewall: web traffic ($WEB_FW)"
if ! gcloud --project "$PROJECT" compute firewall-rules describe "$WEB_FW" >/dev/null 2>&1; then
  gcloud --project "$PROJECT" compute firewall-rules create "$WEB_FW" \
      --allow "tcp:80,tcp:443" \
      --source-ranges "0.0.0.0/0" \
      --target-tags "http-server,https-server" \
      --description "Public HTTP/HTTPS for kosecki.dev"
else
  echo "(already exists, skipping)"
fi

section "Firewall: SSH ($SSH_FW)"
if ! gcloud --project "$PROJECT" compute firewall-rules describe "$SSH_FW" >/dev/null 2>&1; then
  gcloud --project "$PROJECT" compute firewall-rules create "$SSH_FW" \
      --allow "tcp:22" \
      --source-ranges "0.0.0.0/0" \
      --description "SSH for kosecki-tunnel-vm (key auth only)"
else
  echo "(already exists, skipping)"
fi

section "VM ($VM_NAME)"
if ! gcloud --project "$PROJECT" compute instances describe "$VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  ssh_keys_meta="pk:$(cat "$SSH_PUBKEY_FILE")"
  gcloud --project "$PROJECT" compute instances create "$VM_NAME" \
      --zone "$ZONE" \
      --machine-type "$MACHINE" \
      --image-family "debian-12" --image-project "debian-cloud" \
      --network-interface "network-tier=PREMIUM,subnet=default,address=$IP_NAME" \
      --tags "$TAGS" \
      --metadata "ssh-keys=$ssh_keys_meta" \
      --scopes "cloud-platform" \
      --labels "purpose=kosecki-tunnel" \
      --boot-disk-size "10GB" --boot-disk-type "pd-balanced" \
      --boot-disk-auto-delete
else
  echo "(already exists, skipping)"
fi

echo
echo "──────────────────────────────────────────────"
echo "Static IP:    $STATIC_IP"
echo "VM zone:      $ZONE"
echo "VM name:      $VM_NAME"
echo "Project:      $PROJECT"
echo "──────────────────────────────────────────────"
echo
echo "Next step — wait ~30s for VM to finish booting, then:"
echo "  gcloud compute ssh pk@$VM_NAME --zone $ZONE --command 'sudo bash /tmp/setup-vm.sh'"
echo
echo "After setup-vm.sh is done, set the DNS records. Either:"
echo "  CF_API_TOKEN=xxx bash dns/setup-cloudflare.sh $STATIC_IP"
echo "or manually in the Cloudflare dashboard for kosecki.dev:"
echo "  A    @     $STATIC_IP   (DNS-only — gray cloud)"
echo "  A    *     $STATIC_IP   (DNS-only — gray cloud)"
echo
echo "Cost estimate: ~\$3/mo for the static IP. e2-micro usage in europe-central2 is"
echo "covered by free tier + small always-on surcharge (~zero at this size). Set up a"
echo "budget alert at https://console.cloud.google.com/billing/budgets if you want."
