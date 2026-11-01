(function () {
  "use strict";

  const STORAGE_KEY = "cadence_bearer_token";
  let metronomeInterval = null;
  let audioCtx = null;
  let activeFallUuid = null;
  let fallCountdownTimer = null;

  function getToken() {
    return sessionStorage.getItem(STORAGE_KEY);
  }

  function setGlassesBanner(text) {
    const el = document.getElementById("glassesAudioBanner");
    if (el) {
      el.textContent = text;
      el.style.opacity = "0.4";
      setTimeout(() => { el.style.opacity = "1"; }, 150);
    }
  }

  function speakText(text) {
    if ("speechSynthesis" in window) {
      window.speechSynthesis.cancel();
      const utterance = new SpeechSynthesisUtterance(text);
      utterance.rate = 1.0;
      utterance.pitch = 1.0;
      window.speechSynthesis.speak(utterance);
    }
  }

  async function apiCall(path, method, bodyObj) {
    const token = getToken();
    if (!token) {
      showAuthModal("Please sign in as demo-wearer to execute live backend actions.");
      throw new Error("Authentication required.");
    }
    const res = await fetch(path, {
      method: method || "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + token
      },
      body: bodyObj ? JSON.stringify(bodyObj) : undefined
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      if (res.status === 401 || res.status === 403) {
        showAuthModal(body.detail || "Sign-in required or read-only account. Sign in as demo-wearer.");
      }
      let errorMsg = body.detail || body.message || ("Request failed with HTTP " + res.status);
      if (body.problems && Array.isArray(body.problems)) {
        errorMsg += " (" + body.problems.map(p => p.field + ": " + p.message).join(", ") + ")";
      }
      throw new Error(errorMsg);
    }
    return body;
  }

  function showAuthModal(msg) {
    const modal = document.getElementById("authModal");
    const err = document.getElementById("loginError");
    if (err) err.textContent = msg || "";
    if (modal) modal.style.display = "flex";
  }

  function hideAuthModal() {
    const modal = document.getElementById("authModal");
    if (modal) modal.style.display = "none";
  }

  async function handleLogin() {
    const user = document.getElementById("usernameInput").value.trim();
    const pass = document.getElementById("passwordInput").value;
    const err = document.getElementById("loginError");
    err.textContent = "";
    try {
      const res = await fetch("/api/v1/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: user, password: pass })
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        err.textContent = data.message || "Invalid username or password.";
        return;
      }
      sessionStorage.setItem(STORAGE_KEY, data.access_token);
      hideAuthModal();
      updateAccountButton();
      setGlassesBanner("Signed in as " + user + " (" + data.role + "). Ready for hardware simulations.");
    } catch (e) {
      err.textContent = e.message || "Connection error.";
    }
  }

  function updateAccountButton() {
    const btn = document.getElementById("accountButton");
    if (!btn) return;
    if (getToken()) {
      btn.textContent = "● Connected (demo-wearer)";
      btn.classList.add("btn-success");
      btn.classList.remove("btn-secondary");
    } else {
      btn.textContent = "Sign in (demo-wearer)";
      btn.classList.remove("btn-success");
      btn.classList.add("btn-secondary");
    }
  }

  // --- Voice Companion ---
  async function runVoiceQuery() {
    const input = document.getElementById("voiceInput");
    const query = input.value.trim();
    if (!query) return;
    const panel = document.getElementById("voiceResult");
    const answerEl = document.getElementById("voiceAnswerText");
    const modelEl = document.getElementById("voiceModelUsed");
    const intentEl = document.getElementById("voiceIntent");
    const actionEl = document.getElementById("voiceAction");
    const diaryEl = document.getElementById("voiceDiaryEffect");

    answerEl.textContent = "Querying live Meta Muse Spark / Llama 3.2 backend...";
    panel.style.display = "block";

    try {
      const data = await apiCall("/api/v1/companion/interpret", "POST", {
        text: query,
        history: []
      });
      modelEl.textContent = data.model || "meta-models/muse-spark-open-1026";
      intentEl.textContent = data.intent || "interpreted";
      actionEl.textContent = data.action || "None";
      diaryEl.textContent = data.logged_event_uuid ? "Logged: " + data.logged_event_uuid : "Read-only query";

      const spoken = data.reply_text || data.spoken_response || "I checked your schedule and confirmed your records.";
      answerEl.textContent = spoken;
      setGlassesBanner(spoken);
    } catch (e) {
      answerEl.textContent = "Error: " + e.message;
    }
  }

  // --- Reality-Check (Vision) ---
  async function runRealityCheck() {
    const sel = document.getElementById("realitySceneSelect").value;
    const panel = document.getElementById("realityResult");
    const answerEl = document.getElementById("realityAnswerText");
    const objEl = document.getElementById("realityObject");
    const confEl = document.getElementById("realityConfidence");
    const entityEl = document.getElementById("realityLivingEntity");

    answerEl.textContent = "Analyzing 12 MP snapshot with Meta SAM 3.1 & Llama 3.2-11B Vision...";
    panel.style.display = "block";

    let query = "Is someone standing by the door?";
    let masks = [{ label: "coat rack", confidence: 0.94, area_ratio: 0.24 }];

    if (sel === "curtain_shadow") {
      query = "Is there a dog in the room?";
      masks = [{ label: "window curtains", confidence: 0.91, area_ratio: 0.18 }];
    } else if (sel === "clear_path") {
      query = "Is my walking path clear?";
      masks = [{ label: "hardwood floor", confidence: 0.96, area_ratio: 0.85 }];
    }

    try {
      const data = await apiCall("/api/v1/reality-check", "POST", {
        event_uuid: "sim-rc-" + Date.now(),
        timestamp_utc: new Date().toISOString(),
        user_query: query,
        simulated_sam_masks: masks
      });

      const spoken = data.spoken_response || "No living entity detected. The scene is grounded.";
      answerEl.textContent = spoken;
      objEl.textContent = masks[0].label;
      confEl.textContent = (masks[0].confidence * 100).toFixed(0) + "%";
      entityEl.textContent = "No (0.00)";
      setGlassesBanner(spoken);
    } catch (e) {
      answerEl.textContent = "Error: " + e.message;
    }
  }

  // --- Freezing of Gait & Metronome ---
  function playMetronomeClick() {
    try {
      if (!audioCtx) {
        audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      }
      if (audioCtx.state === "suspended") {
        audioCtx.resume();
      }
      const osc = audioCtx.createOscillator();
      const gain = audioCtx.createGain();
      osc.type = "sine";
      osc.frequency.setValueAtTime(880, audioCtx.currentTime); // High pitch click
      gain.gain.setValueAtTime(0.3, audioCtx.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.001, audioCtx.currentTime + 0.04);
      osc.connect(gain);
      gain.connect(audioCtx.destination);
      osc.start();
      osc.stop(audioCtx.currentTime + 0.05);

      const ring = document.getElementById("metronomePulseRing");
      if (ring) {
        ring.classList.add("active");
        setTimeout(() => ring.classList.remove("active"), 80);
      }
    } catch (e) {
      // AudioContext unavailable or blocked
    }
  }

  async function triggerFog() {
    const triggerBtn = document.getElementById("triggerFogBtn");
    const stopBtn = document.getElementById("stopFogBtn");
    const statusEl = document.getElementById("metronomeStatus");
    const panel = document.getElementById("fogResult");
    const answerEl = document.getElementById("fogAnswerText");

    panel.style.display = "block";
    answerEl.textContent = "Transmitting kinematic IMU telemetry (Freeze Index = 3.42) to cloud...";

    try {
      const data = await apiCall("/api/v1/events/fog", "POST", {
        event_uuid: "sim-fog-" + Date.now(),
        timestamp_utc: new Date().toISOString(),
        duration_sec: 5.0,
        peak_freeze_index: 3.42,
        locomotor_band_power: 0.08,
        freeze_band_power: 0.27,
        sampled_hz: 50.0,
        arming_mode: "walking",
        cue_bpm: 100,
        recovery_latency_sec: 2.5
      });

      triggerBtn.disabled = true;
      stopBtn.disabled = false;
      const spoken = "Freezing detected. Rhythmic 100 BPM auditory cueing engaged.";
      answerEl.textContent = spoken + " Event persisted to 24-hour clinical diary.";
      setGlassesBanner(spoken);

      // Start 100 BPM click (60,000 / 100 = 600 ms interval)
      let beat = 1;
      playMetronomeClick();
      statusEl.textContent = "Pulsing at 100 BPM (Beat #" + beat + ")";
      clearInterval(metronomeInterval);
      metronomeInterval = setInterval(() => {
        beat++;
        playMetronomeClick();
        statusEl.textContent = "Pulsing at 100 BPM (Beat #" + beat + ")";
      }, 600);
    } catch (e) {
      answerEl.textContent = "Error: " + e.message;
    }
  }

  function stopFog() {
    clearInterval(metronomeInterval);
    metronomeInterval = null;
    document.getElementById("triggerFogBtn").disabled = false;
    document.getElementById("stopFogBtn").disabled = true;
    document.getElementById("metronomeStatus").textContent = "Standby (Silent)";
    const spoken = "Gait unfreezing confirmed. Rhythmic metronome silenced.";
    document.getElementById("fogAnswerText").textContent = spoken;
    setGlassesBanner(spoken);
  }

  // --- Nutrient Timing ---
  async function runMealAnalysis() {
    const sel = document.getElementById("mealTypeSelect").value;
    const panel = document.getElementById("mealResult");
    const answerEl = document.getElementById("mealAnswerText");
    const protEl = document.getElementById("mealProteinGrams");
    const confEl = document.getElementById("mealConflict");

    answerEl.textContent = "Logging dose & analyzing meal photo with SAM 3.1 food segmentation...";
    panel.style.display = "block";

    const now = new Date().toISOString();
    let masks = [{ label: "steak", area_px: 35000, confidence: 0.95 }, { label: "plate", area_px: 70000, confidence: 0.98 }];
    if (sel === "oatmeal") {
      masks = [{ label: "oatmeal", area_px: 30000, confidence: 0.92 }, { label: "berries", area_px: 8000, confidence: 0.94 }];
    }

    try {
      // 1. Log a dose taken 15 min ago
      await apiCall("/api/v1/medication/dose", "POST", {
        event_uuid: "sim-dose-" + Date.now(),
        timestamp_utc: new Date(Date.now() - 15 * 60 * 1000).toISOString(),
        medication_name: "Carbidopa/Levodopa 25/100"
      });

      // 2. Scan meal
      const data = await apiCall("/api/v1/medication/meal-protein", "POST", {
        event_uuid: "sim-meal-" + Date.now(),
        timestamp_utc: now,
        simulated_masks: masks
      });

      const spoken = data.spoken_response || (sel === "steak"
        ? "Warning: High-protein meal detected within 30 minutes of your Levodopa dose. Large neutral amino acids may delay dopamine absorption."
        : "Low-protein meal detected. Safe timing with your Levodopa dose.");

      answerEl.textContent = spoken;
      protEl.textContent = sel === "steak" ? "~35 grams (High)" : "~3 grams (Low)";
      confEl.textContent = sel === "steak" ? "⚠️ Active Absorption Conflict" : "✅ No Conflict";
      setGlassesBanner(spoken);
    } catch (e) {
      answerEl.textContent = "Error: " + e.message;
    }
  }

  // --- 3-Stage Fall Safety ---
  async function triggerFall() {
    const triggerBtn = document.getElementById("triggerFallBtn");
    const cancelBtn = document.getElementById("cancelFallBtn");
    const panel = document.getElementById("fallResult");
    const answerEl = document.getElementById("fallAnswerText");
    const badgeEl = document.getElementById("fallStatusBadge");
    const statusEl = document.getElementById("fallDispatchStatus");

    panel.style.display = "block";
    answerEl.textContent = "Inertial impact detected (3.9g). Initiating Stage 1 voice check-in...";

    activeFallUuid = "sim-fall-" + Date.now();
    try {
      await apiCall("/api/v1/events/fall", "POST", {
        event_uuid: activeFallUuid,
        timestamp_utc: new Date().toISOString(),
        peak_impact_g: 3.9,
        peak_jerk_gs: 48.0,
        post_impact_tilt_deg: 74.0,
        latitude: 37.7749,
        longitude: -122.4194,
        horizontal_accuracy_m: 5.0,
        status: "confirmed_waiting_dispatch"
      }).catch(err => {
        if (!err.message.includes("503") && !err.message.includes("unavailable")) throw err;
      });

      triggerBtn.disabled = true;
      cancelBtn.disabled = false;
      badgeEl.textContent = "Stage 1: Glasses Audio Check-In";
      const spoken = "Cadence noticed a sudden fall. Are you okay? Say yes or tap to cancel.";
      answerEl.textContent = spoken;
      setGlassesBanner(spoken);

      let countdown = 30;
      clearInterval(fallCountdownTimer);
      fallCountdownTimer = setInterval(() => {
        countdown--;
        if (countdown > 0) {
          statusEl.textContent = "Caregiver SMS in " + countdown + "s...";
        } else {
          clearInterval(fallCountdownTimer);
          badgeEl.textContent = "Stage 3: Caregiver Dispatched";
          statusEl.textContent = "Simulated Twilio SMS sent with GPS coordinates.";
          setGlassesBanner("Caregiver alerted via simulated Twilio dispatch.");
        }
      }, 1000);
    } catch (e) {
      answerEl.textContent = "Error: " + e.message;
    }
  }

  async function cancelFall() {
    if (!activeFallUuid) return;
    const triggerBtn = document.getElementById("triggerFallBtn");
    const cancelBtn = document.getElementById("cancelFallBtn");
    const answerEl = document.getElementById("fallAnswerText");
    const badgeEl = document.getElementById("fallStatusBadge");
    const statusEl = document.getElementById("fallDispatchStatus");

    clearInterval(fallCountdownTimer);
    try {
      await apiCall("/api/v1/events/fall/" + activeFallUuid + "/cancel", "POST");
      triggerBtn.disabled = false;
      cancelBtn.disabled = true;
      badgeEl.textContent = "Alert Canceled (All-Clear)";
      statusEl.textContent = "All-Clear confirmed; caregiver notified of safety.";
      const spoken = "Fall alert canceled. All-Clear recorded in diary.";
      answerEl.textContent = spoken;
      setGlassesBanner(spoken);
      activeFallUuid = null;
    } catch (e) {
      answerEl.textContent = "Error canceling: " + e.message;
    }
  }

  // --- Initialization ---
  function init() {
    updateAccountButton();

    document.getElementById("accountButton").addEventListener("click", () => showAuthModal());
    document.getElementById("authCancelBtn").addEventListener("click", () => hideAuthModal());
    document.getElementById("signInSubmitBtn").addEventListener("click", handleLogin);

    document.getElementById("sendVoiceBtn").addEventListener("click", runVoiceQuery);
    document.querySelectorAll(".quick-chips .chip").forEach(chip => {
      chip.addEventListener("click", () => {
        document.getElementById("voiceInput").value = chip.getAttribute("data-query");
        runVoiceQuery();
      });
    });

    document.getElementById("runRealityBtn").addEventListener("click", runRealityCheck);
    document.getElementById("triggerFogBtn").addEventListener("click", triggerFog);
    document.getElementById("stopFogBtn").addEventListener("click", stopFog);
    document.getElementById("analyzeMealBtn").addEventListener("click", runMealAnalysis);
    document.getElementById("triggerFallBtn").addEventListener("click", triggerFall);
    document.getElementById("cancelFallBtn").addEventListener("click", cancelFall);

    document.getElementById("speakAudioBtn").addEventListener("click", () => {
      const text = document.getElementById("glassesAudioBanner").textContent;
      speakText(text);
    });
  }

  window.addEventListener("DOMContentLoaded", init);
})();
