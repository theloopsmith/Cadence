#!/usr/bin/env bash
# Explicitly invoked deployment. Does not upgrade billing or configure live calls.
set -euo pipefail
[[ $# -ge 1 && $# -le 2 ]] || { echo 'Usage: deploy.sh PROJECT_ID [HOSTNAME]' >&2; exit 2; }
project=$1
[[ "$project" =~ ^[a-z][a-z0-9-]{4,61}[a-z0-9]$ ]] || { echo 'Invalid project ID' >&2; exit 2; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
gcloud_bin=${CADENCE_GCLOUD_BIN:-gcloud}
zone=${CADENCE_GCP_ZONE:-us-central1-a}
region=${zone%-*}
vm=cadence-demo
network=cadence-demo
cloud=("$gcloud_bin" --quiet --project "$project")
# Fail before creating resources when sign-in or billing setup is incomplete.
# This only reads billing state; it never links or upgrades a billing account.
active_account=$("$gcloud_bin" auth list --filter=status:ACTIVE --format='value(account)')
[[ -n "$active_account" ]] || { echo 'Complete gcloud auth login before deploying.' >&2; exit 1; }
"${cloud[@]}" projects describe "$project" --format='value(projectId)' >/dev/null
billing_enabled=$("${cloud[@]}" billing projects describe "$project" --format='value(billingEnabled)')
[[ "$billing_enabled" == True || "$billing_enabled" == true ]] || {
    echo 'Project billing is not enabled. Link the intended trial account in Cloud Console; deployment has stopped.' >&2
    exit 1
}
"${cloud[@]}" services enable compute.googleapis.com iap.googleapis.com
if ! "${cloud[@]}" compute networks describe "$network" >/dev/null 2>&1; then
    "${cloud[@]}" compute networks create "$network" --subnet-mode=auto
fi
if ! "${cloud[@]}" compute firewall-rules describe cadence-demo-web >/dev/null 2>&1; then
    "${cloud[@]}" compute firewall-rules create cadence-demo-web --network "$network" --allow tcp:80,tcp:443 --source-ranges 0.0.0.0/0 --target-tags cadence-demo
fi
if ! "${cloud[@]}" compute firewall-rules describe cadence-demo-iap >/dev/null 2>&1; then
    "${cloud[@]}" compute firewall-rules create cadence-demo-iap --network "$network" --allow tcp:22 --source-ranges 35.235.240.0/20 --target-tags cadence-demo
fi
if ! "${cloud[@]}" compute addresses describe cadence-demo --region "$region" >/dev/null 2>&1; then
    "${cloud[@]}" compute addresses create cadence-demo --region "$region" --network-tier=STANDARD
fi
ip=$("${cloud[@]}" compute addresses describe cadence-demo --region "$region" --format='value(address)')
hostname=${2:-}
if [[ -z "$hostname" && -f "$root/.local/gcp-demo/hostname" ]]; then
    hostname=$(cat "$root/.local/gcp-demo/hostname")
fi
hostname=${hostname:-$ip.sslip.io}
"$root/backend/.venv/bin/python" "$root/scripts/prepare_cloud_demo.py" "$hostname"
python3 "$root/scripts/build_cloud_bundle.py" "$root/.local/gcp-demo/source.tar.gz"
if ! "${cloud[@]}" compute instances describe "$vm" --zone "$zone" >/dev/null 2>&1; then
    "${cloud[@]}" compute instances create "$vm" --zone "$zone" --machine-type=e2-small \
        --image-family=debian-13 --image-project=debian-cloud --boot-disk-size=20GB --boot-disk-type=pd-standard \
        --no-boot-disk-auto-delete --deletion-protection --no-service-account --no-scopes \
        --network "$network" --address "$ip" --network-tier=STANDARD --tags=cadence-demo \
        --metadata=enable-oslogin=TRUE,block-project-ssh-keys=TRUE
fi
ssh_key="$root/.local/gcp-demo/ssh"
common=(--zone "$zone" --tunnel-through-iap --ssh-key-file "$ssh_key")
# Instance creation can finish before IAP lookup and the guest SSH service are
# ready. Probe without uploading secrets, with bounded retries on a fresh VM.
ssh_ready=false
for attempt in {1..12}; do
    if "${cloud[@]}" compute ssh "${common[@]}" "$vm" --command=true \
        --ssh-flag=-oBatchMode=yes --ssh-flag=-oConnectTimeout=15; then
        ssh_ready=true
        break
    fi
    echo "Waiting for IAP/SSH readiness ($attempt/12)..." >&2
    sleep 5
done
[[ "$ssh_ready" == true ]] || { echo 'IAP/SSH is not ready; no credentials uploaded.' >&2; exit 1; }
"${cloud[@]}" compute scp "${common[@]}" "$root/.local/gcp-demo/source.tar.gz" "$root/.local/gcp-demo/backend.env" "$root/.local/gcp-demo/accounts.env" "$vm:~/"
"${cloud[@]}" compute ssh "${common[@]}" "$vm" --command="sudo install -d -m 750 /etc/cadence && sudo install -m 600 backend.env /etc/cadence/backend.env && sudo install -m 600 accounts.env /etc/cadence/accounts.env && rm backend.env accounts.env && tar -xzf source.tar.gz deploy/gcp/install.sh && sudo bash deploy/gcp/install.sh source.tar.gz '$hostname' '$ip.sslip.io'"
printf '%s\n' "$hostname" > "$root/.local/gcp-demo/hostname"
printf 'Deployment started. Verify https://%s/health and https://%s/dashboard\n' "$hostname" "$hostname"
