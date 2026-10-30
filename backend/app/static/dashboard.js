"use strict";
function element(tag, text, className) {
      const node = document.createElement(tag);
      if (text != null) node.textContent = String(text);
      if (className) node.className = className;
      return node;
    }

    function finiteNumber(value, digits=0) {
      return typeof value === "number" && Number.isFinite(value) ? value.toFixed(digits) : "Not measured";
    }

    function safeMapURL(latitude, longitude) {
      if (typeof latitude !== "number" || typeof longitude !== "number" ||
          !Number.isFinite(latitude) || !Number.isFinite(longitude) ||
          Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
      const url = new URL("https://maps.google.com/");
      url.searchParams.set("q", `${latitude},${longitude}`);
      return url.href;
    }

    const STORAGE_KEY = "cadence_bearer_token";

    function getToken() {
      return sessionStorage.getItem(STORAGE_KEY);
    }

    function setGlassesBanner(msg) {
      const el = document.getElementById("glassesAudioBanner");
      el.textContent = "🔊 Glasses Audio: " + msg;
      if ("speechSynthesis" in window) {
        window.speechSynthesis.cancel();
        const u = new SpeechSynthesisUtterance(msg);
        u.rate = 0.95;
        window.speechSynthesis.speak(u);
      }
    }

    async function signIn() {
      const username = document.getElementById("usernameInput").value.trim();
      const password = document.getElementById("passwordInput").value;
      const errorEl = document.getElementById("loginError");
      errorEl.textContent = "";
      if (!username || !password) {
        errorEl.textContent = "Enter your username and password.";
        return;
      }
      const res = await fetch("/api/v1/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password })
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        errorEl.textContent = body.message || "Sign-in didn't work. Please try again.";
        return;
      }
      sessionStorage.setItem(STORAGE_KEY, body.access_token);
      document.getElementById("passwordInput").value = "";
      document.getElementById("authModal").style.display = "none";
      loadReport();
    }

    async function apiPost(path, bodyObj) {
      const token = getToken();
      if (!token) {
        document.getElementById("authModal").style.display = "flex";
        return null;
      }
      const res = await fetch(path, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer " + token
        },
        body: bodyObj ? JSON.stringify(bodyObj) : undefined
      });
      return await res.json();
    }

    async function loadReport() {
      const token = getToken();
      if (!token) {
        document.getElementById("authModal").style.display = "flex";
        return;
      }
      const res = await fetch("/api/v1/report/neurologist", {
        headers: { "Authorization": "Bearer " + token }
      });
      if (res.status === 401 || res.status === 403) {
        sessionStorage.removeItem(STORAGE_KEY);
        document.getElementById("authModal").style.display = "flex";
        return;
      }
      const data = await res.json();
      document.getElementById("narrativeText").textContent = data.clinical_narrative;
      const meta = data.report_metadata;
      const truncated = meta && Object.values(meta.details_truncated || {}).some(Boolean);
      document.getElementById("reportMetadata").textContent = meta
        ? `UTC interval: ${meta.window_start_utc} to ${meta.window_end_utc}. Generated: ${meta.generated_at_utc}. Latest event: ${meta.latest_event_utc ?? "none in this interval"}. ${meta.coverage_note}${truncated ? " Detail lists are limited; totals and timeline include the full interval." : ""}`
        : "Report freshness and observation coverage were not supplied by this server.";
      const st = data.summary_stats;
      document.getElementById("contactEvidence").textContent = `Provider accepted: ${st.caregiver_provider_accepted_count ?? "unknown"}. Caregiver acknowledged: ${st.caregiver_acknowledged_count ?? "unknown"}. Simulated delivery: ${st.simulated_alert_count ?? "unknown"}. Provider acceptance does not establish caregiver receipt.`;
      document.getElementById("doseCount").textContent = st.dose_count ?? 0;
      document.getElementById("beatCount").textContent = st.fog_count;
      document.getElementById("fallCount").textContent = st.fall_count;
      document.getElementById("incidentsCount").textContent = st.fall_candidate_resolved_count || 0;

      const dEl = document.getElementById("examDelta");
      const exams = data.motor_exams || [];
      if (exams.length < 2) {
        dEl.textContent = "Two motor checks are needed to show a change.";
      } else {
        const [latest, prev] = exams;
        const comparable = (a,b,unit) => a == null || b == null ? "Not measured in both checks" : ((a-b >= 0 ? "+" : "") + (a-b).toFixed(0) + unit + " compared with the previous check");
        const letters = p => p == null ? "Not measured" : (Math.abs(p) < 5 ? "about the same size" : Math.abs(p).toFixed(0) + "% " + (p < 0 ? "smaller" : "larger"));
        dEl.textContent = `Letters: ${letters(latest.handwriting_opencv_decay_pct)} (previously ${letters(prev.handwriting_opencv_decay_pct)}). Voice: ${comparable(latest.voice_mean_dbfs, prev.voice_mean_dbfs, " dB")}. Walking: ${comparable(latest.walk_cadence_spm, prev.walk_cadence_spm, " steps a minute")}.`;

      }

      const fList = document.getElementById("fallList");
      if (!data.fall_events || data.fall_events.length === 0) {
        fList.textContent = "No fall events recorded.";
      } else {
        fList.replaceChildren();
        for (const f of data.fall_events) {
          const entry = element("div");
          entry.style.marginBottom = "8px";
          const resolved = f.status === "canceled_false_alarm";
          const words = resolved ? "Answered okay" : ({acknowledged:"Caregiver acknowledged",provider_accepted:"Alert accepted by provider",simulated:"Simulated delivery",exhausted:"Automatic attempts ended",check_in_pending:"Check-in pending",suppressed:"Glasses dropped"}[f.contact_state] || "Alert queued; delivery unverified");
          entry.appendChild(element("span", words, `badge ${resolved ? "badge-ON" : "badge-OFF"}`));
          entry.appendChild(element("span", ` ${f.timestamp_utc ?? "Unknown time"} • impact ${finiteNumber(f.peak_impact_g,1)}g • tilt ${finiteNumber(f.post_impact_tilt_deg)}°`));
          const url = safeMapURL(f.latitude, f.longitude);
          if (url) {
            const link = element("a", " GPS");
            link.href = url;
            link.target = "_blank";
            link.rel = "noopener noreferrer";
            entry.appendChild(link);
          }
          if (f.cancel_transcript) {
            entry.appendChild(element("br"));
            entry.appendChild(element("span", `check-in: “${f.cancel_transcript}”`));
          }
          fList.appendChild(entry);
        }

      }

      const ribbon = document.getElementById("timelineRibbon");
      ribbon.replaceChildren();
      for (const b of (data.buckets_24h || [])) {
        const div = document.createElement("div");
        const pauses = b.fog_count || 0;
        const level = (b.fall_occurred || pauses >= 2) ? "OFF" : (pauses === 1 ? "WEARING_OFF" : ((b.observation_status === "events_logged" || b.has_exam) ? "LOGGED" : "UNKNOWN"));
        const events = [];
        if (pauses) events.push(pauses + (pauses === 1 ? " pause" : " pauses"));
        if (b.fall_occurred) events.push("fall");
        if (b.has_exam) events.push("check");
        div.className = `bucket-pill bucket-${level}`;
        div.appendChild(element("div", b.label_hhmm));
        div.appendChild(element("div", events.join(", ") || (level === "UNKNOWN" ? "No observations" : "Other logs")));
        ribbon.appendChild(div);
      }

      const tbody = document.getElementById("examTableBody");
      tbody.replaceChildren();
      if (!data.motor_exams || data.motor_exams.length === 0) {
        const row = element("tr");
        const cell = element("td", "No motor checks recorded yet. Click Seed Sample Routine above!");
        cell.colSpan = 7;
        row.appendChild(cell);
        tbody.appendChild(row);
      } else {
        for (const ex of data.motor_exams) {
          const tr = document.createElement("tr");
          const p = ex.handwriting_opencv_decay_pct;
          const letters = p == null ? "Not measured" : (Math.abs(p) < 5 ? "about the same" : Math.abs(p).toFixed(0) + "% " + (p < 0 ? "smaller" : "larger"));
          const number = finiteNumber;
          for (const value of [ex.timestamp_utc, number(ex.voice_mean_dbfs), number(ex.voice_stability_db,1), letters, number(ex.walk_cadence_spm), ex.walk_fog_count ?? "Not measured", ex.minutes_since_last_dose ?? "—"]) {
            const cell = document.createElement("td");
            cell.textContent = String(value);
            tr.appendChild(cell);
          }
          tbody.appendChild(tr);
        }
      }

      const rList = document.getElementById("realityList");
      if (!data.reality_checks || data.reality_checks.length === 0) {
        rList.textContent = "None recorded yet.";
      } else {
        rList.replaceChildren();
        for (const r of data.reality_checks) {
          const entry = element("div");
          entry.style.marginBottom = "8px";
          entry.appendChild(element("strong", `“${r.user_query ?? ""}”`));
          entry.appendChild(element("br"));
          entry.appendChild(element("span", `➔ ${r.spoken_response ?? ""}`));
          rList.appendChild(entry);
        }

      }

      const mList = document.getElementById("medList");
      if (!data.medication_logs || data.medication_logs.length === 0) {
        mList.textContent = "None recorded yet.";
      } else {
        mList.replaceChildren();
        for (const m of data.medication_logs) {
          const entry = element("div");
          entry.style.marginBottom = "6px";
          entry.appendChild(element("strong", m.event_type ?? "Event"));
          entry.appendChild(element("span", ` (${m.timestamp_utc ?? "Unknown time"})`));
          if (typeof m.estimated_protein_grams === "number" && Number.isFinite(m.estimated_protein_grams)) {
            entry.appendChild(element("span", ` — ${m.estimated_protein_grams.toFixed(0)}g protein`));
          }
          if (m.conflict_detected) entry.appendChild(element("span", "near a dose", "badge badge-WEARING_OFF"));
          mList.appendChild(entry);
        }

      }
    }

    async function seedDemoTimeline() {
      await apiPost("/api/v1/demo/seed");
      setGlassesBanner("Sample day added.");
      await loadReport();
    }

    async function wipePatientData() {
      const token = getToken();
      if (!token) return;
      await fetch("/api/v1/patient/data", {
        method: "DELETE",
        headers: { "Authorization": "Bearer " + token }
      });
      setGlassesBanner("Diary data wiped.");
      await loadReport();
    }

    async function simFoG() {
      await apiPost("/api/v1/events/fog", {
        event_uuid: "sim-fog-" + Date.now(),
        timestamp_utc: new Date().toISOString(),
        duration_sec: 5.5,
        peak_freeze_index: 3.10,
        locomotor_band_power: 0.09,
        freeze_band_power: 0.28,
        sampled_hz: 100.0,
        arming_mode: "turning_upright",
        cue_bpm: 100,
        recovery_latency_sec: 3.0
      });
      setGlassesBanner("Step with the beat.");
      await loadReport();
    }

    async function simDoseAndSteak() {
      const now = new Date().toISOString();
      await apiPost("/api/v1/medication/dose", {
        event_uuid: "sim-dose-" + Date.now(),
        timestamp_utc: now
      });
      const res = await apiPost("/api/v1/medication/meal-protein", {
        event_uuid: "sim-meal-" + Date.now(),
        timestamp_utc: now,
        simulated_masks: [
          { label: "steak", area_px: 35000, confidence: 0.95 },
          { label: "plate", area_px: 70000, confidence: 0.98 }
        ]
      });
      if (res && res.spoken_response) setGlassesBanner(res.spoken_response);
      await loadReport();
    }

    async function simRealityCheck() {
      const res = await apiPost("/api/v1/reality-check", {
        event_uuid: "sim-rc-" + Date.now(),
        timestamp_utc: new Date().toISOString(),
        user_query: "Is someone standing by the coat rack?",
        simulated_sam_masks: [
          { label: "coat rack", confidence: 0.94, area_ratio: 0.24 }
        ]
      });
      if (res && res.spoken_response) setGlassesBanner(res.spoken_response);
      await loadReport();
    }

    async function simMicrographia() {
      const res = await apiPost("/api/v1/handwriting/analyze", {
        event_uuid: "sim-hw-" + Date.now(),
        timestamp_utc: new Date().toISOString(),
        simulated_letter_heights_px: [44, 41, 38, 34, 30, 28],
        simulated_sam_decay_pct: -29.5,
        source_context: "ambient"
      });
      if (res && res.spoken_response) setGlassesBanner(res.spoken_response);
      await loadReport();
    }

    async function simHomeMotorExam() {
      const res = await apiPost("/api/v1/exam/complete", {
        exam_uuid: "sim-exam-" + Date.now(),
        voice_status: "measured", handwriting_status: "measured", walk_status: "measured",
        measurement_source: "simulated",
        timestamp_utc: new Date().toISOString(),
        voice_mean_dbfs: -16.5,
        voice_stability_db: 1.2,
        handwriting_opencv_decay_pct: -7.5,
        handwriting_sam_decay_pct: -6.9,
        walk_cadence_spm: 105.0,
        walk_mean_fi: 0.80,
        walk_fog_count: 0
      });
      if (res && res.clinical_summary) setGlassesBanner(res.clinical_summary);
      await loadReport();
    }

    async function simFallAndCancel() {
      const uuid = "sim-fall-" + Date.now();
      await apiPost("/api/v1/events/fall", {
        event_uuid: uuid,
        timestamp_utc: new Date().toISOString(),
        peak_impact_g: 3.9,
        peak_jerk_gs: 48.0,
        post_impact_tilt_deg: 74.0,
        latitude: 37.7749,
        longitude: -122.4194,
        horizontal_accuracy_m: 5.0,
        status: "confirmed_waiting_dispatch"
      });
      await apiPost(`/api/v1/events/fall/${uuid}/cancel`);
      setGlassesBanner("Fall alert dispatched and then canceled via All-Clear SMS.");
      await loadReport();
    }

    function initializeDashboard() {
      const actions = {
        seedDemoButton: seedDemoTimeline, wipeButton: wipePatientData,
        printButton: () => window.print(), fogButton: simFoG, mealButton: simDoseAndSteak,
        realityButton: simRealityCheck, writingButton: simMicrographia,
        examButton: simHomeMotorExam, fallButton: simFallAndCancel, signInButton: signIn,
      };
      for (const [id, handler] of Object.entries(actions)) document.getElementById(id).addEventListener("click", handler);
      loadReport();
    }
    window.addEventListener("DOMContentLoaded", initializeDashboard);
