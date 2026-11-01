# Walkthrough playback and photo fixes

The user's latest dark styling, model labels and existing scene assets were retained.

## Behavior

- Play Arun’s day explicitly navigates to the medication scene on the very first click. Navigation uses the visible scene and actual header bounds, rather than the outer tall chapter. Starting or advancing an individual guided exam does not request a scroll.
- Sticky chapters now use normal block flow rather than a vertically centered flex parent; scroll anchoring is disabled to prevent content updates moving the viewport.
- Sound is enabled by default. Narration is unlocked by a Play/Continue gesture; nothing is spoken on page load. Muting is respected. Existing narration-before-countdown and cancellation behavior is retained.
- A highlighted writing chunk is always visible, with additional word underlining when OS speech boundary events are available. Stale boundary callbacks cannot alter a later step.
- Voice, progressive handwriting and walking use distinct images. The notebook grows from the first phrase to the full sentence. Photo review uses a closer, legible capture with the complete writing.
- Countdown number and seconds unit are separate elements with a literal text space and a 14px visual gap.
- Guided photos have no zoom transform and use contain sizing. The full-photo dialog displays the whole image, pauses playback, and closes with the Close button or native Escape behavior. Surroundings reviews use the user's coatstand image.

## Validation

All 217 backend tests and 11 silent virtual-time playback tests passed. Browser checks confirmed the first medication scene is reached; an actual Watch click kept scrollY unchanged (2893.5 before and after); the active writing chunk has a contrasting highlight; the countdown reads 5 seconds; and photo sizing is contain with transform none. At 390×844, the full-photo dialog fits within the viewport without horizontal overflow, and the guided panel and caption have a 14px gap. Existing authentication and simulated caregiver delivery are preserved.

## Image assets and prompts

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
