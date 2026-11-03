# Google Cloud demo deployment

Target project: `ultra-concord-513321-q3`. This deploys a synthetic/demo environment; it does not migrate the Mac's SQLite database or activate real caregiver calls.

## Live demo (verified 2026-11-01)

- Public domain: `https://cadence-companion.duckdns.org`
- Interactive Smart Glasses Walkthrough: <https://cadence-companion.duckdns.org/walkthrough> (alias: `/demo`)
- Caregiver/reviewer dashboard: <https://cadence-companion.duckdns.org/dashboard>
- Published evaluation access: `demo-reviewer` / `cadence-demo-2026` for the read-only dashboard. The dashboard account, its tokens, and the public live tiles close at **2026-11-18 08:00 UTC (November 18, midnight Pacific)**. `DEMO_ACCOUNTS_EXPIRE_AT_UTC` sets that cutoff.
- The public `demo-wearer` writer account is retired, including previously issued tokens. Use a separately provisioned writer account for iPhone testing.

## Layout

- One Debian 13 Compute Engine VM (`e2-small`, 2 GB RAM), one Uvicorn worker, and the existing durable recovery loop.
- SQLite in `/var/lib/cadence/data/demo.sqlite` on a 20 GB standard persistent boot disk. Boot disk auto-deletion is disabled and VM deletion protection is enabled. This is persistent storage, not a backup policy.
- Static IPv4 address and automatic HTTPS via Caddy. The default hostname uses the address under `sslip.io`; an owned hostname can be supplied instead. Certificate issuance and DNS must be verified before sharing.
- Dedicated VPC, only public TCP 80/443, SSH reachable through Google's IAP source range. No Google service account is attached to the VM.
- `public_demo` startup requires a persistent signing secret, disabled static development tokens, enabled simulated transports, no Twilio credentials, disabled research metrics, and the reviewed Meta model IDs. Interactive API docs/schema are unavailable on the public demo.
- The read-only dashboard binds to `hackathon-demo`. Provider keys and the signing key remain private.

The judge endpoint accepts one fixed action, with the sample chosen by the backend. Its defaults are **1,000 tile runs per UTC day**, **8 runs per minute per IP**, and **4 simultaneous runs** on the single-worker VM. Set `JUDGE_DEMO_DAILY_RUNS`, `JUDGE_DEMO_RUNS_PER_IP_MINUTE`, or `JUDGE_DEMO_MAX_CONCURRENT` before deployment to override them. SQLite atomically reserves a daily slot before inference and keeps the count across restarts. Every admitted attempt counts. A surroundings run can make up to eight provider requests, so the daily cap measures tile runs rather than API requests or dollars. Rejections return HTTP 429 with `Retry-After`.

Ordinary paid-inference routes share a 30-request/minute sliding window per authenticated account (per configured bearer for local static tokens). Re-signing in does not reset the account budget. Responses return 429 and Retry-After before provider work. Urgent fall-check-in transcription has a separate bounded 60/minute account budget; non-inference event ingestion stays outside these inference quotas. The limiter is process-local, resets on restart and is not a provider spending cap; use one worker and provider-side budgets.

## Local preparation

Run the existing backend environment's Python for configuration generation because it includes python-dotenv. `scripts/build_cloud_bundle.py` copies only allowlisted application source, the dependency lock and installer. Environment files, local records, databases, Git metadata and caches are excluded.

The Google CLI was downloaded from Google's official distribution and its published SHA-256 verified. It is installed at `/private/tmp/cadence-gcloud-tools/google-cloud-sdk/bin/gcloud` for this setup. Sign-in is isolated under `.local/gcloud`, and no shell profile was modified. This temporary executable path may need reinstalling after system cleanup; using an installed `gcloud` on PATH also works.

## Deploy after completing Google sign-in

From the repository root:

```sh
export CLOUDSDK_CONFIG="$PWD/.local/gcloud"
export CLOUDSDK_PYTHON="$PWD/backend/.venv/bin/python"
export CADENCE_GCLOUD_BIN=/private/tmp/cadence-gcloud-tools/google-cloud-sdk/bin/gcloud
./deploy/gcp/deploy.sh ultra-concord-513321-q3 cadence-companion.duckdns.org
```

The script verifies sign-in, project access and linked billing before enabling Compute and IAP APIs. It creates the VM/network/address if absent, uploads code and private environment files over IAP, installs pinned dependencies, creates scoped accounts, and starts the service. A newly enabled API can take several minutes to propagate; if Google reports `SERVICE_DISABLED` immediately after successful activation, wait and rerun. Re-running preserves the database and locally saved signing key/passwords. Keep the ignored deployment files backed up privately; losing them complicates subsequent deployments.

Cloud resources consume trial credit, including compute, IPv4 and storage. This VM is not the always-free e2-micro configuration. Do not upgrade the account to paid billing automatically. Verify trial status and credit balance in the Cloud Console and remove resources after judging. The script does not set a budget alert, hard spending cap, or automated cleanup.

## Acceptance before sharing

1. Confirm public HTTPS and read-only dashboard access.
2. Check that the retired writer and anonymous patient data access are rejected.
3. Run a fixed sample from **For Judges** and confirm live model output.

Use the reusable smoke checker with the actual HTTPS origin:

```sh
backend/.venv/bin/python scripts/verify_cloud_demo.py https://HOSTNAME
# Restart cadence using the IAP SSH connection, then:
backend/.venv/bin/python scripts/verify_cloud_demo.py https://HOSTNAME --after-restart
```

The checker verifies fixed-input inference, writer retirement, and read-only dashboard access. It saves the reviewer token in ignored `.local/gcp-demo/judge-acceptance.json` for the restart check. Keep that file private.

## Operational commands

Use `gcloud compute ssh cadence-demo --project ultra-concord-513321-q3 --zone us-central1-a --tunnel-through-iap` and inspect `sudo systemctl status cadence` or `sudo journalctl -u cadence`. Do not print the environment file or credentials into shared logs.

For cleanup after judging, inspect the project resources in Cloud Console. VM deletion protection must be turned off explicitly. The boot disk is retained by design; delete the retained disk, reserved address, firewall rules and dedicated network when no longer needed. Stopping the VM alone can leave storage/address charges consuming credit.

After a successful deployment the selected primary hostname is saved in ignored `.local/gcp-demo/hostname`. Later deployments without a hostname argument reuse it. Share only the primary origin above. The IP-derived hostname is an installation detail, not a supported judge fallback.

Before the retired-column migration, the installer makes a private SQLite backup under `/var/lib/cadence/backups`. The active database removes the retired columns transactionally while keeping observation IDs and indexes. Backups are not served by the website.
