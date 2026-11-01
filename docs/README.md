# Cadence documentation

Start with [the project README](../README.md) for the product, setup, model provenance and live demo.

- [Architecture and design contract](ARCHITECTURE_AND_DESIGN_SPEC.md): current ownership, models, measurement contracts, fall sequence, privacy and native experience.
- [Editable architecture](cadence_architecture.drawio): five pages—system, fall safety, Meta calls, data/privacy, and generated storage schema. [Schema SVG](assets/storage-schema.svg) opens directly in a browser.
- [Cloud demo runbook](GOOGLE_CLOUD_DEMO.md): deployment, protected credentials, role separation, restart checks and operational limits.
- [Walkthrough implementation and asset provenance](WALKTHROUGH_DESIGN.md): browser behavior, synthetic/live boundaries and image prompts.
- [Verification log](VERIFICATION_LOG.md) and [sanitized evidence](verification/): dated checks, failure cases and limits. Historical entries are not the current status of a feature.
- [Hackathon guide](<Details – Meta Global AI Developer Hackathon – Cerebral Valley.pdf>): the supplied rules snapshot. Scope and contribution-date questions still need an organizer reply.
- [Branding source](branding/README.md): icon asset provenance and regeneration instructions.

## Current acceptance gates

The app and backend are implemented and CI-tested; physical acceptance remains separate. The public walkthrough and real-photo traces distinguish illustration, provider execution and hardware proof.

1. Record organizer decisions on accessibility scope and the October 26/27 start boundary. Preserve actual Git history and identify eligible new contributions.
2. The [real-photo SAM + Muse cloud journey](verification/real-photo-meta-2026-11-01.json) is verified with an approved iPhone image. A [supplied Meta glasses JPEG](verification/glasses-photo-meta-2026-11-01.json) is also verified through both models. These exports do not establish live capture within Cadence DAT or audio routing. The [initial filtered result](verification/real-photo-meta-2026-11-01-initial.json) and [decoded SAM diagnostic](verification/sam-live-2026-11-01.json) remain alongside the successful result.
3. Install the current iPhone build and test the glasses camera, audible prompts/cues, stop, interruption, disconnect/reconnect and microphone denial. Narrow the demo's claims for any unverified path.
4. Keep caregiver transport explicitly simulated until a consenting, configured live delivery/acknowledgment drill is recorded.
5. Finish the accessible three-minute video, contributor/representative declaration, asset-rights confirmation and event-built contribution statement.

## Maintenance

Keep current guides here; implementation history belongs in Git and the verification log. The dated readiness review and separate repair notes were consolidated into these guides. No source code, private photo, credential, or database belongs in this directory.

Run from the repository root:

```sh
python3 scripts/sync_architecture_docs.py
python3 scripts/sync_architecture_docs.py --check
python3 scripts/check_docs.py
```

CI checks generated diagram freshness and local Markdown links. Provider traces are sanitized evidence, not automated tests and not clinical validation.
