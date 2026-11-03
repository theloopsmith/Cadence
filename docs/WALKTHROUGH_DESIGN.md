# Walkthrough and static artwork

Live page: <https://cadence-companion.duckdns.org/walkthrough> (`/demo` is an alias).

The reference is Apple's [MacBook Pro display page](https://www.apple.com/macbook-pro/proled-xdr-display/): generous spacing, large restrained typography, product-led imagery, and a story that advances with scrolling. No Apple assets or copy were reused.

## Experience

The opening introduces Cadence explicitly as an iPhone app used with Ray-Ban Meta glasses. A wearer portrait zooms into a glasses-frame transition and a first-person morning scene. Five sequential chapters cover the guided voice-writing-walking check, medication history/confirmation, rhythmic walking support, photo confirmation and surroundings descriptions, and a simulated care-partner escalation. The final scene shows an illustrative iPhone diary and a link to the real authenticated dashboard.

Each chapter has three scroll-driven beats. Captions, the highlighted step, and an app receipt change together. Short phone screens use ordinary scrolling; reduced-motion settings remove the pinning/zooming/footstep animation. All chapter steps remain readable without JavaScript. Narration is enabled by default and uses OS/browser speech synthesis. Story-page load attempts a short welcome when the browser allows autoplay. If a tap is required, Enable sound and Play/Continue unlock narration; it can be muted. It stops when the page is hidden or the user switches it off. There is no looping metronome or microphone request.

The story is illustrative. It never writes data on scroll, runs a real motor exam, claims delivery/acknowledgment occurred, or presents a glasses HUD as implemented hardware. Synthetic safety behavior is labeled. Removed the prior page's invented medication replies and nutrition/absorption advice.

## Live judge run

**For Judges** offers four independent tiles for live medication intent, surroundings, handwriting photo quality, and voice transcription. The photo tiles use illustrated images. The transcription tile uses a short synthetic WAV clip. Each tile displays its own provider output or fallback. Photo previews and transcripts do not write diary entries.

The tiles call a public endpoint that accepts only an action name and supplies its own sample. A persistent daily quota, a per-IP limit, and a concurrency limit apply before model inference.

## Source and visual assets

- `backend/app/static/walkthrough.html`: semantic page and illustrative app view.
- `backend/app/static/walkthrough.css`: responsive presentation, reduced motion and print rules.
- `backend/app/static/walkthrough.js`: scroll states, optional OS speech, separately authenticated backend proof.
- `backend/app/static/walkthrough/wearer.jpg`
- `backend/app/static/walkthrough/table.jpg`
- `backend/app/static/walkthrough/hall.jpg`
- `backend/app/static/walkthrough/desk.jpg`
- Other retained scene assets: `coatstand.jpg`, `safety_floor.jpg`, `together.jpg`, `motor-voice.jpg`, `writing-first.jpg`, `writing-second.jpg`, `writing-complete.jpg`, `handwriting-capture.jpg`. All are in the same directory and exact server allowlist.

The retained generated-asset prompts are below. On November 2, 2026, Harshal Vaidya confirmed that `coatstand.jpg` and `safety_floor.jpg` were generated using ChatGPT. They are static fictional illustrations, not patient photos, physical-device captures or evidence of measured behavior. No image generator is called at runtime. See [submission declarations](SUBMISSION_DECLARATIONS.md) for asset scope and outstanding organizer confirmation.

Original raster artwork was generated with the built-in `image_gen` tool during development and encoded as JPEG for delivery. This introduces no OpenAI model call at app/page runtime. Originals remain in the local generated-images directory. The page uses only same-origin images/CSS/JS, the existing per-response script nonce, and an exact allowlist for image delivery; unknown image names return 404. No provider credentials are embedded in assets.

### Image prompts

**Wearer:** Use case: photorealistic-natural. Asset type: premium website hero photograph, wide 16:9 landscape. A warm, dignified Indian man aged about 62, salt-and-pepper hair, pale stone cotton shirt, photographed frontally from chest up on a seamless warm light gray studio background. He is gently putting on chunky black Wayfarer-style smart glasses, both hands lightly holding the temples beside his face. Authentic human expression, independent and calm, looking toward camera. Frame person centered with generous empty space on left and right, complete head and shoulders visible. Quiet editorial portrait, soft natural side light, highly realistic skin and hands, crisp restrained consumer technology campaign photography. No logos, text, graphics, medical props, interface, futuristic effects or displays in the lenses.

**Table:** Use case: photorealistic-natural. Asset type: first-person scene for a premium accessibility app website, wide landscape 16:9. First-person camera at seated eye height looking down slightly at a sunlit warm oak breakfast table in a contemporary calm home. Two hands of an older Indian adult visible naturally at bottom edges, a closed small white weekly pill organizer, one plain amber medicine bottle with a blank white label, clear glass of water, cream linen napkin. Nothing being swallowed, no loose pills. Beautiful warm natural morning window light, realistic subtle materials and shadows. Spacious deliberate composition with objects in lower half and calm empty dining room background above. Real photography, no text, no logos, no HUD or overlays.

**Hall:** Use case: photorealistic-natural. Asset type: first-person scene for premium smart glasses companion walkthrough, wide 16:9 landscape. A person's natural eye-level first-person view down a quiet, bright contemporary home hallway into a sunlit living room, warm pale oak floor, cream plaster walls, simple bench, a coat hanging on a slim coat stand near the doorway on the right. A small leafy plant and soft morning daylight. No people visible, no stairs, no obstacles blocking the path. Honest photographic perspective, inviting everyday home, beautiful material detail, restrained neutral palette. Wide angle but no fisheye. No text, no graphics, no logos, no holograms, no AR interface.

**Desk:** Use case: photorealistic-natural. Asset type: premium website first-person POV photograph, wide landscape 16:9. First-person view from an older Indian adult seated at a pale oak desk in the same bright warm minimalist home, looking down at a clean open cream notebook. Right hand with natural age texture holds a black pen above the mostly blank right page, left hand rests near the notebook. A subtle short handwritten loop mark on one page, no legible text. Soft daylight, light cream sleeve, quiet organized setting, authentic hands, crisp realistic photography, ample unobstructed background above the notebook. No phone screen, no UI, no medical props, no branding or text.

## Guided journeys and human story

The tour now follows fictional Arun and his daughter Maya through ordinary plans for the day, ending with an illustrative scene of tea together. This is a product scenario, not a patient testimonial or claim of clinical efficacy. Parkinson's is the current product focus; assistance for other conditions is explicitly a future direction.

“Play Arun’s day” plays the five feature journeys in sequence, then moves to the care diary. Each chapter can also be played alone or explored using previous/next controls. A fixed player keeps pause, previous, next, and stop reachable on phones. Deliberate user scrolling or hiding the page pauses playback; returning to the page does not resume it. The ordinary scroll tour remains available.

The motor journey has eleven beats, grounded in `ios/CadenceCompanion/DSP/MotorExamGuidance.swift`: introduction, voice readiness, five-second sustained-vowel illustration, writing setup, the actual three writing chunks (“The quick brown fox” / “jumps over” / “the lazy dog.”), glasses photo capture, explicit photo confirmation, ten-second walking illustration, and a sample summary. Writing narration runs at a slower rate, and each six-second writing pause begins after OS speech ends. Capture countdowns also begin after the spoken instruction. The browser does not record audio, open a camera, measure movement, generate exam scores, or save a fake motor exam.

Medication demonstrates a saved-plan lookup, the distinction between no record and not having taken a dose, explicit ingestion statement, confirmation, saving, and later factual recall. Surroundings demonstrates the request, glasses capture, photo review, confirmation, qualified description, and diary follow-through. Safety distinguishes the check-in, queued contact, provider acceptance and a simulated human acknowledgment. None of these illustrative journeys calls an API. The separately authenticated backend proof remains available below the story.

Added silent virtual-time tests in `backend/tests/walkthrough_playback.test.cjs`, wired into CI. They verify no background network calls, narration-before-countdown ordering, full dictation pauses, stale-callback cancellation, hidden-page pause, and full-day progression to the care view.

### Closing image prompt

Saved project asset: `backend/app/static/walkthrough/together.jpg`. Built-in `image_gen` used the original wearer portrait as a character reference; the generated source PNG was retained and encoded as JPEG for the page.

Use the man in the supplied portrait as a character reference, preserving his recognizable face, age around 62, salt and pepper hair, cream linen shirt and chunky black smart glasses. Create a new photorealistic editorial lifestyle photograph, wide landscape 16:9, for the closing scene of a premium accessibility companion website. He is now sitting outside at a warm oak garden table on the veranda of a calm contemporary home in late afternoon sunlight, enjoying tea and a relaxed, authentic conversation with his adult daughter, an Indian woman around 35 in a muted sage cotton shirt. They face each other naturally, smiling subtly, attentive and equal; the daughter is not providing physical assistance. Two ceramic tea cups on the table, green garden beyond, soft gold light, everyday intimacy and dignity. Medium wide composition with both complete faces visible, no camera posing, no medical props, no sad expressions or heroic triumph, no text, no logos, no screens, no interface, no watermarks. Quiet cinematic photography with realistic human hands and natural skin, beautiful restrained colors. This is a fictional illustrative scene, not a patient testimonial.

## Playback and photo behavior

The first full-day Play navigates to the motor scene (01, 07:45), followed by medication (02, 08:00). Playback reads the chapter order from the HTML. Individual task controls do not request a scroll. Deliberate wheel/touch/key scrolling pauses playback; responsive layout changes and programmatic navigation do not. Switching tabs, hiding the page and opening photo review also pause. Speech and timers are fenced against stale callbacks.

The Experience / How it works tabs use an equal-column grid to stay centered independently of the brand and audio controls. Very narrow phones use a second header row. Sound activation may require a browser gesture even though narration defaults on.

The active writing chunk remains highlighted, with word underlining when the OS supplies boundary events. Each task has appropriate voice/writing/walking imagery; countdown values and units have visible spacing. Photos use contain sizing without zoom, with a full-image review dialog.

## Guided-task asset prompts



Five original project-bound images were created with the built-in image_gen tool. Existing source artwork was used as character/scene reference. Generated PNGs were retained and encoded as JPEGs in the project. No runtime model API was added.

### motor-voice.jpg

Project path: `backend/app/static/walkthrough/motor-voice.jpg`

Use the same man in this reference, preserving his face, age around 62, salt-and-pepper hair, cream shirt and black smart glasses. New wide 16:9 photograph for a guided voice sample: he sits comfortably in a warm bright living room, hands resting naturally on his lap, mouth gently open sustaining a comfortable ah sound, calm attentive expression, chest-up three-quarter camera angle, not looking at camera. Soft natural daylight, dignified realistic photography, generous quiet background. No text, no UI, no logos or medical equipment.

### writing-first.jpg

Project path: `backend/app/static/walkthrough/writing-first.jpg`

Edit this first-person photograph preserving the same notebook, hands, cream sleeves, desk, daylight and camera perspective. Replace the tiny loop mark on the right notebook page with clearly legible natural black-ink handwriting that reads exactly: "The quick brown fox". Spell every word correctly, no extra words or marks. The hand holding the pen is positioned just after the last written word. Let the writing flow across two gently spaced lines on the right page if needed, comfortably inside page margins. The left page stays blank. Make the right page's complete writing visible with generous clear margins and no hand or pen obscuring any letters. Realistic ordinary handwriting, crisp readable ink, natural photography. No captions, no printed typography, no UI or logos.

### writing-second.jpg

Project path: `backend/app/static/walkthrough/writing-second.jpg`

Edit this first-person photograph preserving the same notebook, hands, cream sleeves, desk, daylight and camera perspective. Replace the tiny loop mark on the right notebook page with clearly legible natural black-ink handwriting that reads exactly: "The quick brown fox jumps over". Spell every word correctly, no extra words or marks. The hand holding the pen is positioned just after the last written word. Let the writing flow across two gently spaced lines on the right page if needed, comfortably inside page margins. The left page stays blank. Make the right page's complete writing visible with generous clear margins and no hand or pen obscuring any letters. Realistic ordinary handwriting, crisp readable ink, natural photography. No captions, no printed typography, no UI or logos.

### writing-complete.jpg

Project path: `backend/app/static/walkthrough/writing-complete.jpg`

Edit this first-person photograph preserving the same notebook, hands, cream sleeves, desk, daylight and camera perspective. Replace the tiny loop mark on the right notebook page with clearly legible natural black-ink handwriting that reads exactly: "The quick brown fox jumps over the lazy dog.". Spell every word correctly, no extra words or marks. The hand holding the pen is positioned just after the last written word. Let the writing flow across two gently spaced lines on the right page if needed, comfortably inside page margins. The left page stays blank. Make the right page's complete writing visible with generous clear margins and no hand or pen obscuring any letters. Realistic ordinary handwriting, crisp readable ink, natural photography. No captions, no printed typography, no UI or logos.

### handwriting-capture.jpg

Project path: `backend/app/static/walkthrough/handwriting-capture.jpg`

Create a closer, readable photo review of the completed right-hand notebook page in this reference. Preserve the exact black-ink handwriting "The quick brown fox jumps over the lazy dog." with correct spelling and period, same warm daylight and cream paper. Camera is now almost directly above the right page, showing the ENTIRE right page including all four edges and generous margins, with the page occupying 85 percent of the image. The left blank page can appear as a narrow strip at left; most desk clutter is out of frame. Keep a small part of the older man's hand and pen near the outside right edge but do not cover any text. The sentence is handwritten large across two or three lines in the central part of the page and very clearly legible. Landscape 4:3 framing. This is a photorealistic glasses-camera image of the actual notebook, not a flat generated text document. No digital UI, captions, labels, branding or other writing.

## App icon

The final icon is an ivory C with an aqua terminal on a deep teal square. It is intentionally simple enough for the iPhone home screen. iOS supplies the corner mask.

- App asset: [App icon](../ios/App/CadenceCompanionApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png) (1024 × 1024, opaque).
- Generated master: [Generated master](branding/Cadence-icon-master.png) (1254 × 1254, opaque).
- Generation: built-in image generation tool, during development. This is a bundled static asset; the app adds no runtime image-generation model call.
- Packaging: master resized with macOS sips to the app-icon dimensions, without changing the design. AppIcon is selected for Debug and Release targets.

### Icon generation prompt

Use case: logo-brand. Asset type: production iPhone home-screen app icon for Cadence, a calm voice-first daily living companion that helps people move with a steady rhythm. Create ONE final square icon, 1024 by 1024 pixels if possible. Full-bleed opaque deep midnight teal background. Center a single distinctive, bold, warm ivory C-shaped mark: a clean open circular ribbon with subtly staggered rounded ends suggesting gentle forward steps and cadence. One restrained soft aqua accent on the lower terminal, integrated into the C, not a separate badge. Large simple silhouette, very legible at 40 pixels, generous safe area (mark within central 66% of canvas), beautifully balanced negative space. Flat refined vector-like finish, smooth edges, no noise or texture. No text, no wordmark, no letters other than the implied C, no medical cross, no ECG/heartbeat line, no glasses drawing, no gradients, no shadows, no mockup, no phone frame, no rounded outer corners, no border. The background fills all four square corners; iOS supplies the mask.
