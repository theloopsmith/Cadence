# Cadence documentation

Start with [the project README](../README.md) for the product, setup, model provenance and live demo.

- [App setup and voice guide](APP_GUIDE.md): phone/server connection, glasses permissions, guided tasks, medication reminders and troubleshooting.
- [Architecture and design contract](ARCHITECTURE_AND_DESIGN_SPEC.md): current ownership, models, measurement contracts, fall sequence, privacy and native experience.
- [Rendered implementation map](assets/system-architecture.svg) and [editable architecture](cadence_architecture.drawio): five pages—system, fall safety, Meta calls, data/privacy, and generated storage schema. [Schema SVG](assets/storage-schema.svg) opens directly in a browser.
- [Cloud demo runbook](GOOGLE_CLOUD_DEMO.md): deployment, protected credentials, role separation, restart checks and operational limits.
- [Walkthrough implementation and asset provenance](WALKTHROUGH_DESIGN.md): browser behavior, synthetic/live boundaries and image prompts.
- [Verification log](VERIFICATION_LOG.md) and [sanitized evidence](verification/): dated checks, failure cases and limits. Historical entries are not the current status of a feature.
- [Hackathon guide](<Details – Meta Global AI Developer Hackathon – Cerebral Valley.pdf>): the supplied rules snapshot. Scope and contribution-date questions still need an organizer reply.
- [Icon source and prompt](WALKTHROUGH_DESIGN.md#app-icon): retained with the static-artwork provenance, alongside the [editable image master](branding/Cadence-icon-master.png).

## Current acceptance gates

The app and backend are implemented and CI-tested; physical acceptance remains separate. The public walkthrough and real-photo traces distinguish illustration, provider execution and hardware proof.

1. Record organizer decisions on accessibility scope and the October 26/27 start boundary. Preserve actual Git history and identify eligible new contributions.
2. The [real-photo SAM + Muse cloud journey](verification/real-photo-meta-2026-11-01.json) is verified with an approved iPhone image. A [supplied Meta glasses JPEG](verification/glasses-photo-meta-2026-11-01.json) is also verified through both models. A [general-question pipeline trace](verification/general-scene-meta-2026-11-01.json) verifies Muse image proposals followed by independent SAM grounding; a [deployed HTTP check](verification/general-scene-http-2026-11-01.json) exercises the same general question through authentication and response contracts. These exports do not establish live capture within Cadence DAT or audio routing. The [initial filtered result](verification/real-photo-meta-2026-11-01-initial.json) and [decoded SAM diagnostic](verification/sam-live-2026-11-01.json) remain alongside the successful result.
3. Install the current iPhone build and test the glasses camera, audible prompts/cues, stop, interruption, disconnect/reconnect and microphone denial. Narrow the demo's claims for any unverified path.
4. Keep caregiver transport explicitly simulated until a consenting, configured live delivery/acknowledgment drill is recorded.
5. Finish the accessible three-minute video, contributor/representative declaration, asset-rights confirmation and event-built contribution statement.

## Maintenance

Each guide has one purpose: app operation, architecture, cloud operation, web/asset provenance, or verification. Superseded screenshots and historical implementation diaries remain in Git rather than competing with current guidance. The rules snapshot and branding master are retained for attribution and submission review. No private photo, credential or database belongs here.

Run from the repository root:

```sh
python3 scripts/sync_architecture_docs.py
python3 scripts/sync_architecture_docs.py --check
python3 scripts/check_docs.py
```

CI checks generated diagram freshness and local Markdown links. Provider traces are sanitized evidence, not automated tests and not clinical validation.
