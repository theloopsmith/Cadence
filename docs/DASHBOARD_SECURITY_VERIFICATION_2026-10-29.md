# Dashboard stored-text security — October 29, 2026

Item 5 from the readiness review is implemented and verified.

## Changes

All dynamic report sections now construct DOM nodes and set text with `textContent`: fall timestamps/transcripts, scene questions/responses, medication entries, timeline labels, task rows, comparisons and narrative. No HTML parsing sink remains in the dashboard JavaScript. Refreshing a report replaces its previous rows.

GPS links use a fixed HTTPS Google Maps origin and encoded query parameters. Both coordinates must be finite numeric values inside latitude/longitude bounds. Nulls, strings, infinities and out-of-range values produce no link. Links opened in a new tab retain `noopener noreferrer`.

Dashboard JavaScript moved to `/assets/dashboard.js`; fixed button IDs bind handlers with `addEventListener`. `/dashboard` generates a fresh random script nonce on each response and includes a matching Content Security Policy. The policy allows the nonce-authorized script, blocks inline handlers and other scripts, restricts connections to the same origin, and forbids plugins, base-URL changes and framing. HTML and script responses use no-store caching and `nosniff`; HTML also uses `Referrer-Policy: no-referrer`.

Existing inline **styles** remain allowed for the current layout. The script policy does not allow unsafe-inline or eval. Authentication still uses a bearer token in `sessionStorage`; this task fixes the identified injection paths and adds a browser-enforced second layer, not HttpOnly-cookie authentication or certification of the whole application.

## Verification

- **154 Python tests pass**, including nonce/header matching, nonce freshness, no caching, no inline handlers, JavaScript content type, forbidden sink checks, and no shipped development bearer tokens in either HTML or JavaScript. Two pre-existing deprecation warnings remain.
- **Four JavaScript checks pass** against the actual report renderer with DOM/fetch doubles: partial measurements and real zeros; hostile strings across report sections; bounded GPS links; and control listener wiring. Run `node --test backend/tests/dashboard_exam_validity.test.cjs`.
- An **isolated real headless Chrome check passes** using the actual HTML, response headers and JavaScript obtained from FastAPI's public routes, plus an in-memory hostile-text report. It verifies text stays inert, the nonce-authorized script loads, sign-in button wiring works, normal load produces no policy violations/page errors, and intentionally injected inline scripts, un-nonced same-origin scripts and inline event handlers are blocked. All requests were intercepted; there were zero unexpected page requests. See [recorded browser result](verification/dashboard-browser-security-2026-10-29.json).
- `git diff --check` passes. Swift code was unchanged in this security item; the previous **262 passing Swift tests and successful iOS app build** remain the latest iOS verification, not a new rerun.

The browser check is `backend/tests/dashboard_browser_security.cjs`. It accepts a JSON fixture path containing `html`, `headers`, `script`, and `script_headers` from `TestClient(app).get('/dashboard')` and `.get('/assets/dashboard.js')`. Run with Node and Playwright installed. `CADENCE_BROWSER_EXECUTABLE` can select an installed Chrome executable; otherwise Playwright uses its installed browser. The local check used a fresh temporary browser profile with muted audio; the user's existing browser profile was not used. The sandbox initially prevented browser launch; the isolated process subsequently ran with approved execution access and closed successfully.

No database records, live credentials, model inference, caregiver calls or audio playback were involved. This does not establish production proxy/header configuration, all-browser compatibility, full visual QA, or the unrelated report time/coverage correctness. Deploy the updated HTML route, JavaScript route and asset together, preserve CSP/security headers, and serve the page through FastAPI rather than opening the HTML directly from disk.

Design references: MDN's [textContent documentation](https://developer.mozilla.org/en-US/docs/Web/API/Node/textContent) and [script-src policy documentation](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/script-src). The observed behavior above is backed by the local tests, not inferred solely from the documentation.
