# Google Cloud demo deployment

Target project: `ultra-concord-513321-q3`. This deploys a synthetic/demo environment; it does not migrate the Mac's SQLite database or activate real caregiver calls.

## Live demo (verified 2026-11-01)

- Public domain: `https://cadence-companion.duckdns.org`
- Interactive Smart Glasses Walkthrough: <https://cadence-companion.duckdns.org/walkthrough> (alias: `/demo`)
- Caregiver/reviewer dashboard: <https://cadence-companion.duckdns.org/dashboard>
- Phone server origin: `https://cadence-companion.duckdns.org` (fallback IP origin: `https://35.209.6.236.sslip.io`)
- Published sandbox evaluation access: `demo-reviewer` / `cadence-demo-2026` for read-only review; `demo-wearer` / `cadence-demo-2026` for synthetic writes and limited live inference. These temporary credentials are intended only for the judging window. They are not production credentials; do not submit personal/clinical data. Retire both accounts after judging and invalidate their existing tokens; automatic expiry is not configured.
- In the iPhone app, open Settings, expand the developer options, and use Account and local history to enter the HTTPS origin and phone account. A new server/account is a separate profile: preserve/export existing local records before any deliberate local reset. Do not bypass the account-bound queue guard or repoint another wearer's pending records.
- For a fresh demo build, Xcode's `CADENCE_SERVER_URL` build setting can provide this origin through the existing Info.plist setting. Existing saved server preferences take precedence; no phone's profile was changed during deployment.
- Public TLS, anonymous/static-token rejection, both account roles, reader write rejection, a live Muse Spark Open classification, and persistence of a synthetic record/server identity/original JWTs across a service restart all passed. Physical iPhone/glasses use and real caregiver delivery remain unverified; delivery is intentionally simulated.

## Layout

- One Debian 13 Compute Engine VM (`e2-small`, 2 GB RAM), one Uvicorn worker, and the existing durable recovery loop.
- SQLite in `/var/lib/cadence/data/demo.sqlite` on a 20 GB standard persistent boot disk. Boot disk auto-deletion is disabled and VM deletion protection is enabled. This is persistent storage, not a backup policy.
- Static IPv4 address and automatic HTTPS via Caddy. The default hostname uses the address under `sslip.io`; an owned hostname can be supplied instead. Certificate issuance and DNS must be verified before sharing.
- Dedicated VPC, only public TCP 80/443, SSH reachable through Google's IAP source range. No Google service account is attached to the VM.
- `public_demo` startup requires a persistent signing secret, disabled static development tokens, enabled simulated transports, no Twilio credentials, disabled research metrics, and the reviewed Meta model IDs. Interactive API docs/schema are unavailable on the public demo.
- `demo-wearer` is the iPhone writer account; `demo-reviewer` is the read-only dashboard account. Both bind to `hackathon-demo`. Deployment credential state and the signing key remain in ignored `.local/gcp-demo/` files. The published evaluation passwords above are intentionally public and must remain confined to the sandbox; provider keys and signing secrets are never published.

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

1. Confirm public `/health` and `/dashboard` load over valid HTTPS.
2. Verify login with the demo accounts; check that anonymous access to patient API data and shared development tokens fails, and reviewer writes fail.
3. Make one synthetic Meta question request and verify the selected model without uploading patient records.
4. Restart the service, then verify the same credentials, data and authenticated access still work.
5. Test the iPhone against the new address. Its existing Mac-bound local profile is intentionally not migrated or erased. Follow the app's profile-boundary guidance; export/preserve existing local records before choosing a reset or separate demo profile/build.
6. Keep caregiver delivery visibly simulated. Real Twilio requires a separately configured and authorized environment.

The live results above record acceptance for the current deployment. Future redeploys still need these checks; a successful local test suite or source bundle alone is not evidence of a working cloud deployment.

Use the reusable smoke checker with the actual HTTPS origin:

```sh
backend/.venv/bin/python scripts/verify_cloud_demo.py https://HOSTNAME
# Restart cadence using the IAP SSH connection, then:
backend/.venv/bin/python scripts/verify_cloud_demo.py https://HOSTNAME --after-restart
```

The initial pass checks TLS, authentication, role enforcement and a live Meta classification, then writes one `SYNTHETIC DEPLOYMENT CHECK` dose to the isolated demo patient. It saves a private baseline in ignored `.local/gcp-demo/acceptance.json`; this contains JWTs and must not be shared. The restart pass reuses those original tokens and verifies the same server identity and saved record. Neither pass displays credentials or deletes records. This automated check does not verify iPhone/glasses audio, camera behavior or real caregiver delivery.

## Operational commands

Use `gcloud compute ssh cadence-demo --project ultra-concord-513321-q3 --zone us-central1-a --tunnel-through-iap` and inspect `sudo systemctl status cadence` or `sudo journalctl -u cadence`. Do not print the environment file or credentials into shared logs.

For cleanup after judging, inspect the project resources in Cloud Console. VM deletion protection must be turned off explicitly. The boot disk is retained by design; delete the retained disk, reserved address, firewall rules and dedicated network when no longer needed. Stopping the VM alone can leave storage/address charges consuming credit.

After a successful deployment the selected primary hostname is saved in ignored `.local/gcp-demo/hostname`. Later deployments without a hostname argument reuse it. Caddy also serves the reserved IP’s sslip.io hostname as a fallback, so deploying frontend changes does not silently replace the friendly address.
