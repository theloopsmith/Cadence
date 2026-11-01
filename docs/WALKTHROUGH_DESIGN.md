# Cadence wearer walkthrough

Live page: <https://35.209.6.236.sslip.io/walkthrough> (`/demo` is an alias).

The reference is Apple's [MacBook Pro display page](https://www.apple.com/macbook-pro/proled-xdr-display/): generous spacing, large restrained typography, product-led imagery, and a story that advances with scrolling. No Apple assets or copy were reused.

## Experience

The opening introduces Cadence explicitly as an iPhone app used with Ray-Ban Meta glasses. A wearer portrait zooms into a glasses-frame transition and a first-person morning scene. Five sequential chapters cover medication history/confirmation, the guided voice-writing-walking check, rhythmic walking support, photo confirmation and surroundings descriptions, and a simulated care-partner escalation. The final scene shows an illustrative iPhone diary and a link to the real authenticated dashboard.

Each chapter has three scroll-driven beats. Captions, the highlighted step, and an app receipt change together. Short phone screens use ordinary scrolling; reduced-motion settings remove the pinning/zooming/footstep animation. All chapter steps remain readable without JavaScript. Narration is enabled by default and uses OS/browser speech synthesis. Story-page load attempts a short welcome when the browser allows autoplay. If a tap is required, Enable sound and Play/Continue unlock narration; it can be muted. It stops when the page is hidden or the user switches it off. There is no looping metronome or microphone request.

The story is illustrative. It never writes data on scroll, runs a real motor exam, claims delivery/acknowledgment occurred, or presents a glasses HUD as implemented hardware. Synthetic safety behavior is labeled. Removed the prior page's invented medication replies and nutrition/absorption advice.

## Live backend proof

The judge panel is collapsed below the story. Explicit sign-in is required, using a device-writer account bound to `hackathon-demo`; a clinician-reader account cannot run it. Tokens remain in browser memory and are discarded on reload/sign-out. Password inputs are cleared after submission. API redirects are rejected. Login and sequence operations have bounded deadlines; sign-out aborts in-flight requests and invalidates late responses.

One explicit run calls the existing Meta intent endpoint, writes a labeled synthetic dose and walking event, then verifies both UUIDs in the authenticated report. Model fallback is displayed honestly. Partial writes remain saved if a later stage fails; a subsequent explicit run creates a new set of IDs. The panel does not call a fall, caregiver dispatch, food-advice, or fake motor-completion endpoint. The story and the real backend proof are clearly distinguished.

## Source and visual assets

- `backend/app/static/walkthrough.html`: semantic page and illustrative app view.
- `backend/app/static/walkthrough.css`: responsive presentation, reduced motion and print rules.
- `backend/app/static/walkthrough.js`: scroll states, optional OS speech, separately authenticated backend proof.
- `backend/app/static/walkthrough/wearer.jpg`
- `backend/app/static/walkthrough/table.jpg`
- `backend/app/static/walkthrough/hall.jpg`
- `backend/app/static/walkthrough/desk.jpg`

Original raster artwork was generated with the built-in `image_gen` tool during development and encoded as JPEG for delivery (about 1.5 MB combined). This introduces no OpenAI model call at app/page runtime. Originals remain in the local generated-images directory. The page uses only same-origin images/CSS/JS, the existing per-response script nonce, and an exact allowlist for image delivery; unknown image names return 404. No provider credentials are embedded in assets.

### Image prompts

**Wearer:** Use case: photorealistic-natural. Asset type: premium website hero photograph, wide 16:9 landscape. A warm, dignified Indian man aged about 62, salt-and-pepper hair, pale stone cotton shirt, photographed frontally from chest up on a seamless warm light gray studio background. He is gently putting on chunky black Wayfarer-style smart glasses, both hands lightly holding the temples beside his face. Authentic human expression, independent and calm, looking toward camera. Frame person centered with generous empty space on left and right, complete head and shoulders visible. Quiet editorial portrait, soft natural side light, highly realistic skin and hands, crisp restrained consumer technology campaign photography. No logos, text, graphics, medical props, interface, futuristic effects or displays in the lenses.

**Table:** Use case: photorealistic-natural. Asset type: first-person scene for a premium accessibility app website, wide landscape 16:9. First-person camera at seated eye height looking down slightly at a sunlit warm oak breakfast table in a contemporary calm home. Two hands of an older Indian adult visible naturally at bottom edges, a closed small white weekly pill organizer, one plain amber medicine bottle with a blank white label, clear glass of water, cream linen napkin. Nothing being swallowed, no loose pills. Beautiful warm natural morning window light, realistic subtle materials and shadows. Spacious deliberate composition with objects in lower half and calm empty dining room background above. Real photography, no text, no logos, no HUD or overlays.

**Hall:** Use case: photorealistic-natural. Asset type: first-person scene for premium smart glasses companion walkthrough, wide 16:9 landscape. A person's natural eye-level first-person view down a quiet, bright contemporary home hallway into a sunlit living room, warm pale oak floor, cream plaster walls, simple bench, a coat hanging on a slim coat stand near the doorway on the right. A small leafy plant and soft morning daylight. No people visible, no stairs, no obstacles blocking the path. Honest photographic perspective, inviting everyday home, beautiful material detail, restrained neutral palette. Wide angle but no fisheye. No text, no graphics, no logos, no holograms, no AR interface.

**Desk:** Use case: photorealistic-natural. Asset type: premium website first-person POV photograph, wide landscape 16:9. First-person view from an older Indian adult seated at a pale oak desk in the same bright warm minimalist home, looking down at a clean open cream notebook. Right hand with natural age texture holds a black pen above the mostly blank right page, left hand rests near the notebook. A subtle short handwritten loop mark on one page, no legible text. Soft daylight, light cream sleeve, quiet organized setting, authentic hands, crisp realistic photography, ample unobstructed background above the notebook. No phone screen, no UI, no medical props, no branding or text.

## Guided journeys and human story (second iteration)

The tour now follows fictional Arun and his daughter Maya through ordinary plans for the day, ending with an illustrative scene of tea together. This is a product scenario, not a patient testimonial or claim of clinical efficacy. Parkinson's is the current product focus; assistance for other conditions is explicitly a future direction.

“Play Arun’s day” plays the five feature journeys in sequence, then moves to the care diary. Each chapter can also be played alone or explored using previous/next controls. A fixed player keeps pause, previous, next, and stop reachable on phones. Scrolling or hiding the page pauses playback; returning to the page does not resume it. The ordinary scroll tour remains available.

The motor journey has eleven beats, grounded in `ios/CadenceCompanion/DSP/MotorExamGuidance.swift`: introduction, voice readiness, five-second sustained-vowel illustration, writing setup, the actual three writing chunks (“The quick brown fox” / “jumps over” / “the lazy dog.”), glasses photo capture, explicit photo confirmation, ten-second walking illustration, and a sample summary. Writing narration runs at a slower rate, and each six-second writing pause begins after OS speech ends. Capture countdowns also begin after the spoken instruction. The browser does not record audio, open a camera, measure movement, generate exam scores, or save a fake motor exam.

Medication demonstrates a saved-plan lookup, the distinction between no record and not having taken a dose, explicit ingestion statement, confirmation, saving, and later factual recall. Surroundings demonstrates the request, glasses capture, photo review, confirmation, qualified description, and diary follow-through. Safety distinguishes the check-in, queued contact, provider acceptance and a simulated human acknowledgment. None of these illustrative journeys calls an API. The separately authenticated backend proof remains available below the story.

Added silent virtual-time tests in `backend/tests/walkthrough_playback.test.cjs`, wired into CI. They verify no background network calls, narration-before-countdown ordering, full dictation pauses, stale-callback cancellation, hidden-page pause, and full-day progression to the care view.

### Closing image prompt

Saved project asset: `backend/app/static/walkthrough/together.jpg`. Built-in `image_gen` used the original wearer portrait as a character reference; the generated source PNG was retained and encoded as JPEG for the page.

Use the man in the supplied portrait as a character reference, preserving his recognizable face, age around 62, salt and pepper hair, cream linen shirt and chunky black smart glasses. Create a new photorealistic editorial lifestyle photograph, wide landscape 16:9, for the closing scene of a premium accessibility companion website. He is now sitting outside at a warm oak garden table on the veranda of a calm contemporary home in late afternoon sunlight, enjoying tea and a relaxed, authentic conversation with his adult daughter, an Indian woman around 35 in a muted sage cotton shirt. They face each other naturally, smiling subtly, attentive and equal; the daughter is not providing physical assistance. Two ceramic tea cups on the table, green garden beyond, soft gold light, everyday intimacy and dignity. Medium wide composition with both complete faces visible, no camera posing, no medical props, no sad expressions or heroic triumph, no text, no logos, no screens, no interface, no watermarks. Quiet cinematic photography with realistic human hands and natural skin, beautiful restrained colors. This is a fictional illustrative scene, not a patient testimonial.

See [playback and photo repair notes](WALKTHROUGH_REPAIR_NOTES.md) for the current scroll behavior, phase-specific motor imagery, full-photo viewer, and image prompts.
