(function () {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const chapters = Array.from(document.querySelectorAll('[data-chapter]'));
  const intro = document.querySelector('.intro');
  const soundButton = $('soundButton');
  let soundEnabled = 'speechSynthesis' in window;
  let narrationUnlocked = false;
  soundButton.setAttribute('aria-pressed', String(soundEnabled));
  soundButton.textContent = soundEnabled ? 'Enable sound ◉' : 'Audio unavailable';
  soundButton.disabled = !soundEnabled;
  let activeChapter = null;
  let lastSpoken = '';
  let framePending = false;
  let playback = null;
  let playbackRevision = 0;
  let playbackTimer = null;
  let playbackFrame = null;
  let pendingNarrationDone = null;

  // These captions describe a sample day. Scrolling never invokes an API,
  // requests microphone access, creates records, or contacts a caregiver.
  const story = {
    medication: {
      you: ['“Did I log my morning medication?”', '“I took it. Save that.”', '“Yes, save it.”'],
      replies: ['“I don’t see a dose saved for this morning.”', '“You’ve said you took it. Shall I save that?”', '“Saved. Your morning dose is in your diary.”'],
      receipts: ['Morning dose · Not yet recorded', 'Morning dose · Awaiting confirmation', 'Morning dose · Confirmed by you · 08:00']
    },
    motor: {
      you: ['“I want to do my motor check.”', '“Read the phrase slowly, please.”', '“I’m ready for the walking part.”'],
      replies: ['“Let’s start with your voice. I’ll guide you.”', '“Now write the phrase. Take your time.”', '“Next, a short walk — only if you feel safe.”'],
      receipts: ['Daily check · Voice sample', 'Daily check · Handwriting photo', 'Daily check · Walking sample']
    },
    walking: {
      replies: ['A familiar beat, through your audio.', 'A steady rhythm to follow, one step at a time.', 'The walking event stays in your day’s record.'],
      receipts: ['Walking protection · Monitoring', 'Rhythmic audio cue · Playing in this example', 'Walking event · Saved in this example']
    },
    surroundings: {
      you: ['“Help me check what’s by the door.”', '“Use this photo.”', '“What does the photo show?”'],
      replies: ['“Let’s take a photo with your glasses.”', '“Would you like to use this photo?”', '“The photo check suggests a coat and coat rack. Detections may be mistaken.”'],
      receipts: ['Photo · Waiting for your confirmation', 'Photo · Confirmed by you', 'Image description · Added to your diary']
    },
    safety: {
      replies: ['Time to answer. A chance to cancel.', 'If there is no response, an alert can escalate.', 'A delivery receipt is not an acknowledgment. Cadence tracks both.'],
      receipts: ['Check-in · Waiting for a response', 'Contact attempt · Simulated', 'Acknowledgment · Simulated example only']
    }
  };

  let cachedVoices = [];
  function refreshVoices() {
    if ('speechSynthesis' in window) {
      cachedVoices = window.speechSynthesis.getVoices().filter((v) => v.lang && v.lang.startsWith('en'));
    }
  }
  if ('speechSynthesis' in window) {
    refreshVoices();
    window.speechSynthesis.onvoiceschanged = refreshVoices;
  }

  function getBestHumanVoice() {
    if (!cachedVoices.length) refreshVoices();
    if (!cachedVoices.length) return null;
    const natural = cachedVoices.find((v) => /natural|neural/i.test(v.name));
    if (natural) return natural;
    const enhanced = cachedVoices.find((v) => /premium|enhanced/i.test(v.name));
    if (enhanced) return enhanced;
    const google = cachedVoices.find((v) => /google\s+us\s+english|google\s+uk\s+english\s+female/i.test(v.name));
    if (google) return google;
    const warm = cachedVoices.find((v) => /samantha|ava|allison|karen|zoe|serena|fiona|daniel/i.test(v.name));
    if (warm) return warm;
    const nonRobotic = cachedVoices.find((v) => !/alex|fred|junior|ralph|albert|bad news|bahh|bells|boing|bubbles|cellos|deranged|good news|hysterical|pipe organ|trinoids|whisper|zarvox/i.test(v.name));
    return nonRobotic || cachedVoices[0];
  }

  function silence() {
    if (pendingNarrationDone) pendingNarrationDone();
    if ('speechSynthesis' in window) window.speechSynthesis.cancel();
  }

  function speak(text, key) {
    if (!soundEnabled || !narrationUnlocked || lastSpoken === key || document.hidden) return;
    silence();
    lastSpoken = key;
    const utterance = new SpeechSynthesisUtterance(text.replace(/[“”]/g, ''));
    utterance.lang = 'en-US';
    utterance.rate = 0.92;
    utterance.pitch = 1.0;
    const voice = getBestHumanVoice();
    if (voice) utterance.voice = voice;
    utterance.onstart = () => { if (lastSpoken !== key || !soundEnabled) return; narrationUnlocked = true; soundButton.textContent = 'Sound on ◉'; };
    utterance.onerror = event => {
      if (lastSpoken === key && event.error === 'not-allowed') { narrationUnlocked = false; soundButton.textContent = 'Enable sound ◉'; }
    };
    window.speechSynthesis.speak(utterance);
  }

  function updateScene(chapter, stage) {
    const name = chapter.dataset.chapter;
    if (chapter.dataset.stage === String(stage)) return;
    chapter.dataset.stage = String(stage);
    if (name === 'motor') updateMotorScene(chapter, {visual:stage === 0 ? 'voiceReady' : stage === 1 ? 'writing' : 'walk', chunk:stage === 1 ? 2 : -1});
    if (story[name].you) chapter.querySelector('.you-said').textContent = story[name].you[stage];
    chapter.querySelector('[data-reply]').textContent = story[name].replies[stage];
    chapter.querySelector('[data-receipt]').textContent = story[name].receipts[stage];
    chapter.querySelectorAll('[data-step]').forEach((step, index) => step.classList.toggle('is-current', index === stage));
  }

  const clamp = (value) => Math.max(0, Math.min(1, value));
  function renderScroll() {
    framePending = false;
    const height = window.innerHeight;
    const introRect = intro.getBoundingClientRect();
    if (!reducedMotion.matches && introRect.bottom > 0 && introRect.top < height) {
      const progress = clamp((60 - introRect.top) / Math.max(1, introRect.height - height + 60));
      document.querySelector('.hero-copy').style.transform = `translateY(${-progress * 100}px)`;
      document.querySelector('.hero-copy').style.opacity = String(1 - clamp(progress * 2));
      document.querySelector('.portrait-wrap').style.transform = `scale(${1 + progress * 0.2})`;
      document.querySelector('.portrait-wrap').style.opacity = String(1 - clamp((progress - 0.5) * 2));
      document.querySelector('.intro-world').style.opacity = String(clamp((progress - 0.45) * 2.5));
      const lens = document.querySelector('.intro-lens');
      lens.style.transform = `translate(-50%,${160 - progress * 230}%) scale(${0.75 + progress * 2.7})`;
      lens.style.opacity = String(clamp((progress - 0.1) * 2) * (1 - clamp((progress - 0.8) * 5)));
    }
    let nextActive = null;
    for (const chapter of chapters) {
      const rect = chapter.getBoundingClientRect();
      const active = rect.top < height * 0.5 && rect.bottom > height * 0.5;
      chapter.classList.toggle('is-active', active);
      const progress = reducedMotion.matches ? 0 : clamp((60 - rect.top) / Math.max(1, rect.height - height + 60));
      const stage = progress < 0.28 ? 0 : progress < 0.67 ? 1 : 2;
      if ((!playback || playback.chapter !== chapter) && rect.bottom > 0 && rect.top < height) updateScene(chapter, stage);
      if (active) nextActive = chapter;
    }
    if (!playback && activeChapter && !nextActive) silence();
    // Viewport centers change during our own scrolls and responsive layouts.
    // Only actual user scroll input below pauses a guided journey.
    // Only announce when smoothly arriving at a new chapter, starting cleanly from stage 0
    if (!playback && soundEnabled && nextActive && nextActive !== activeChapter) {
      speak(story[nextActive.dataset.chapter].replies[0], nextActive.id + ':0');
    }
    activeChapter = nextActive;
  }
  function scheduleFrame() {
    if (framePending) return;
    framePending = true;
    window.requestAnimationFrame(renderScroll);
  }

  soundButton.addEventListener('click', () => {
    if (!('speechSynthesis' in window)) {
      soundButton.textContent = 'Audio unavailable';
      soundButton.disabled = true;
      return;
    }
    // A browser-blocked first play is an unlock action, not a mute action.
    soundEnabled = !narrationUnlocked || !soundEnabled;
    narrationUnlocked = true;
    soundButton.setAttribute('aria-pressed', String(soundEnabled));
    soundButton.textContent = soundEnabled ? 'Sound on ◉' : 'Sound off ◌';
    lastSpoken = '';
    if (!soundEnabled) silence();
    else if (playback && playback.playing) { void showBeat(playback.chapter, playback.index, true, playback.allDay); }
    else if (playback) { /* Continue remains an explicit action after a pause. */ }
    else if (activeChapter) {
      const stage = Number(activeChapter.dataset.stage || 0);
      speak(story[activeChapter.id].replies[stage], activeChapter.id + ':' + stage);
    } else speak('Welcome to Cadence. Scroll to experience a day with your companion.', 'welcome');
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { pausePlayback(); silence(); }
    // Never resume speech automatically after switching back to this tab.
  });
  window.addEventListener('pagehide', silence);
  reducedMotion.addEventListener('change', scheduleFrame);
  window.addEventListener('scroll', scheduleFrame, {passive: true});
  window.addEventListener('wheel', pausePlayback, {passive:true});
  window.addEventListener('touchmove', pausePlayback, {passive:true});
  window.addEventListener('keydown', event => {
    const target = event.target;
    if (target && /INPUT|TEXTAREA|SELECT|BUTTON/.test(target.tagName)) return;
    if (['ArrowDown','ArrowUp','PageDown','PageUp','Home','End',' '].includes(event.key)) pausePlayback();
  });
  window.addEventListener('resize', scheduleFrame, {passive: true});
  document.documentElement.classList.add('enhanced');
  chapters.forEach((chapter) => updateScene(chapter, 0));
  renderScroll();
  if (soundEnabled && window.location.hash !== '#how-it-works') {
    narrationUnlocked = true;
    speak('Welcome to Cadence. Play Arun’s day to follow along.', 'welcome');
  }

  // The playable journeys use the iPhone flow's prompts, but all captures,
  // confirmations and outcomes below are illustrations, not measurements.
  const journeys = {
    medication: [
      {group:0,user:'“What’s in my morning routine?”',reply:'Your saved routine has a morning medication reminder at eight.',receipt:'Saved routine · Morning reminder · 08:00',visual:'routine',title:'His routine, ready to ask about',detail:'Morning medication · 08:00',duration:4500},
      {group:0,user:'“Did I already record it?”',reply:'I don’t see a dose recorded this morning. A missing record does not tell me whether you took it.',receipt:'Today’s diary · No morning dose recorded',visual:'question',title:'A record, not a guess',detail:'Cadence checks what was saved. It does not infer whether a medicine was taken.',duration:5500},
      {group:1,user:'“I took it. Log that.”',reply:'You’ve said you took your morning medication. Shall I save that?',receipt:'Dose record · Waiting for confirmation',visual:'confirm',title:'Arun stays in control',detail:'“Yes, save it.”',duration:4500},
      {group:2,user:'“Yes, save it.”',reply:'Saved. Your diary now shows that you confirmed your morning medication at eight.',receipt:'Morning dose · Confirmed by Arun · 08:00',visual:'saved',title:'A detail he can return to',detail:'Morning dose · Confirmed by you · 08:00',duration:5000},
      {group:2,user:'Later: “Did I log my morning medication?”',reply:'Yes. You confirmed your morning dose at eight.',receipt:'Later question · Answered from the saved record',visual:'saved',title:'The answer is still there later',detail:'Confirmed record → a factual answer',duration:5000}
    ],
    motor: [
      {group:0,user:'“I want to do a motor exam.”',reply:'We’ll do three short tasks: your voice, your handwriting, and a short walk. You can skip any task or stop whenever you need.',receipt:'Daily check · Three guided tasks',visual:'overview',title:'One instruction at a time',detail:'Voice → Writing → Walking',duration:4500},
      {group:0,user:'“Ready.”',reply:'Sit comfortably. Use a comfortable breath and voice. After I say begin, hold a steady ah for five seconds.',receipt:'Voice sample · Waiting to begin',visual:'voiceReady',title:'First, his voice',detail:'A comfortable, steady “ah” for 5 seconds.',duration:3500},
      {group:0,user:'“Ahhhhh…”',reply:'Begin.',receipt:'Voice sample · Five-second illustration',visual:'voice',title:'Hold a comfortable “ah”',detail:'Illustrative sample · The browser is not recording.',count:5,duration:5000},
      {group:1,user:'“I’m ready for the writing part.”',reply:'Sit comfortably with paper and a pen. Write at your usual size. I’ll read the sentence in three short parts, with time to write each part.',receipt:'Writing · Paper and pen ready',visual:'writing',title:'Time to write, at his own pace',detail:'Repeat or skip is always available.',chunk:-1,duration:3500},
      {group:1,user:'He starts the first part.',reply:'The quick brown fox',receipt:'Writing · Part 1 of 3',visual:'writing',title:'The first part. Then a pause.',detail:'Six seconds to write after the spoken phrase.',chunk:0,duration:6000},
      {group:1,user:'The next part, when he is ready.',reply:'jumps over',receipt:'Writing · Part 2 of 3',visual:'writing',title:'A short phrase. Room to finish.',detail:'Six seconds to write after the spoken phrase.',chunk:1,duration:6000},
      {group:1,user:'And the last few words.',reply:'the lazy dog.',receipt:'Writing · Part 3 of 3',visual:'writing',title:'No rush to keep up.',detail:'Say “repeat” in the app to hear the sentence again.',chunk:2,duration:6000},
      {group:1,user:'“Take a photo.”',reply:'Here is the whole page. Review the writing, then choose whether to use this photo.',receipt:'Handwriting · Glasses photo captured in this example',visual:'photo',title:'Review the complete handwriting',detail:'Illustrative photo · No camera is accessed here.',image:'handwriting-capture',duration:3500},
      {group:1,user:'“Use this photo.”',reply:'Photo accepted. Next is a ten-second walk, only if you feel steady and have a clear path.',receipt:'Handwriting photo · Confirmed by Arun',visual:'photoAccepted',title:'He chooses the photo to keep',detail:'Confirmed photo → the handwriting step can continue.',image:'handwriting-capture',duration:4000},
      {group:2,user:'“Ready for the walk.”',reply:'Keep your usual walking aid if you use one. Only walk if you feel steady and have a clear path. Begin.',receipt:'Walking · Ten-second illustration',visual:'walk',title:'A short walk, when safe',detail:'Head motion is tracked through your glasses. This is a visual illustration.',count:10,duration:10000},
      {group:2,user:'“What gets saved?”',reply:'Your voice sample, handwriting observations, and walking observations stay together in your diary. You can share the record with your care team.',receipt:'Daily check · Sample summary ready',visual:'summary',title:'Something concrete to look back on',detail:'Illustrative summary · No exam or measurements were performed here.',duration:6500}
    ],
    walking: [
      {group:0,user:'He heads toward the garden.',reply:'With walking protection enabled, Cadence can watch for a possible pause in movement.',receipt:'Walking protection · Enabled in this example',visual:'walking',title:'A day already in motion',detail:'His hands stay free. Head motion is tracked through his glasses.',duration:4500},
      {group:0,user:'A step does not come easily.',reply:'A possible walking pause has been noticed. A rhythmic cue can offer something steady to follow.',receipt:'Possible movement pause · Noticed',visual:'pause',title:'A moment to pause',detail:'An illustrative event, not live sensor detection.',duration:4500},
      {group:1,user:'A little rhythm, through his audio.',reply:'The cue is there to support him, one step at a time. It does not guarantee recovery.',receipt:'Rhythmic cue · Illustrated',visual:'rhythm',title:'A steady beat to follow',detail:'Visual rhythm only · No metronome is played by this tour.',duration:5000},
      {group:2,user:'The moment has a place in his record.',reply:'The walking event is kept in the diary, so it does not have to be recalled later.',receipt:'Walking event · Saved in the sample day',visual:'saved',title:'A small moment, remembered',detail:'Walking event → today’s diary',duration:4500}
    ],
    surroundings: [
      {group:0,user:'“Help me check what’s by the door.”',reply:'Let’s take a photo with your glasses, then you can choose whether to use it.',receipt:'Surroundings · Waiting for a photo',visual:'camera',title:'Start with what he is looking at',detail:'The glasses provide the camera view in the real app.',image:'coatstand',duration:4500},
      {group:0,user:'“Take a photo.”',reply:'Here is the captured photo. Would you like to use it or take another?',receipt:'Glasses photo · Ready to review',visual:'photo',title:'A photo he can review',detail:'Illustrative capture · No browser camera access.',image:'coatstand',duration:4000},
      {group:1,user:'“Use this photo.”',reply:'I’ll check the image you chose.',receipt:'Photo · Confirmed by Arun',visual:'photoAccepted',title:'He decides what is used',detail:'Retake, use, or cancel. The choice stays with him.',image:'coatstand',duration:3500},
      {group:2,user:'“What does it appear to show?”',reply:'This photo appears to show a coat and coat rack.',receipt:'Image description · Ready to hear',visual:'description',title:'Tentative photo labels',detail:'Illustrative output · Recognition accuracy has not been benchmarked.',image:'coatstand',duration:5000},
      {group:2,user:'He can ask again, or carry on.',reply:'You can keep this description in your diary.',receipt:'Confirmed image description · In the sample diary',visual:'saved',title:'Help without taking the choice away',detail:'His photo. His confirmation. His next step.',duration:4500}
    ],
    safety: [
      {group:0,user:'A possible fall interrupts the day.',reply:'Cadence noticed a possible fall. Are you okay?',receipt:'Possible fall · Check-in started',visual:'checkIn',title:'First, a chance to answer',detail:'He can answer or cancel a false alarm.',duration:4500},
      {group:0,user:'In this scenario, Arun does not respond.',reply:'The check-in window gives him time to respond. This tour compresses the wait.',receipt:'Check-in · No response in this example',visual:'checkIn',title:'Time to respond',detail:'Waiting is compressed in this illustrative tour.',duration:4500},
      {group:1,user:'The unresolved alert can reach his chosen person.',reply:'An unresolved alert can queue an attempt to contact Maya, his configured care partner.',receipt:'Care partner contact · Simulated attempt queued',visual:'caregiver',title:'Maya · Chosen care partner',detail:'Possible fall alert. Please check in with Arun.',duration:5000},
      {group:2,user:'Was it delivered? Has someone answered?',reply:'A provider accepting a message is not the same as a person acknowledging it. Cadence keeps those states separate.',receipt:'Simulated provider acceptance · Acknowledgment pending',visual:'caregiver',title:'Accepted is not acknowledged',detail:'Provider accepted · Waiting for a human response',duration:5000},
      {group:2,user:'Maya acknowledges in this example.',reply:'The acknowledgment is now part of the alert record. The cloud demo simulates this entire delivery sequence.',receipt:'Maya · Acknowledgment simulated',visual:'acknowledged',title:'An acknowledgment he can see',detail:'Simulated acknowledgment · No message or call was sent.',duration:5500}
    ]
  };

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function updateMotorScene(chapter, beat) {
    if (chapter.id !== 'motor') return;
    const image = chapter.querySelector('.scene > img');
    let asset = 'wearer';
    let alt = 'Arun preparing for the guided motor check.';
    if (beat.visual === 'voice' || beat.visual === 'voiceReady') {
      asset = 'motor-voice'; alt = 'Arun sitting comfortably for a sustained voice sample.';
    } else if (beat.visual === 'writing') {
      asset = beat.chunk < 0 ? 'desk' : ['writing-first', 'writing-second', 'writing-complete'][beat.chunk];
      alt = 'Illustrative notebook showing the writing completed so far.';
    } else if (beat.visual === 'photo' || beat.visual === 'photoAccepted' || beat.visual === 'summary') {
      asset = beat.visual === 'summary' ? 'writing-complete' : 'handwriting-capture'; alt = 'The notebook with the complete handwritten sentence.';
    } else if (beat.visual === 'walk') {
      asset = 'hall'; alt = 'A clear home hallway for the short walking task.';
    }
    image.src = '/assets/walkthrough/' + asset + '.jpg';
    image.alt = alt;
  }

  function openPhoto(beat) {
    pausePlayback();
    const image = $('photoViewerImage');
    image.src = '/assets/walkthrough/' + beat.image + '.jpg';
    image.alt = beat.image === 'handwriting-capture' ? 'The complete handwritten sentence on the notebook page.' : 'The full illustrative surroundings photo.';
    $('photoViewerCaption').textContent = beat.image === 'handwriting-capture'
      ? 'Illustrative handwriting: The quick brown fox jumps over the lazy dog.'
      : 'Illustrative photo review. The complete image is shown without cropping.';
    $('photoViewer').showModal();
  }

  function renderTask(chapter, beat) {
    const task = chapter.querySelector('.demo-task');
    task.hidden = false;
    task.className = 'demo-task task-' + beat.visual;
    task.replaceChildren();
    task.appendChild(element('small', 'task-kicker', chapter.id === 'motor' ? 'ILLUSTRATIVE EXAM · NO RECORDING' : 'ILLUSTRATIVE STEP'));
    task.appendChild(element('strong', 'task-title', beat.title));
    if (beat.visual === 'writing') {
      const line = element('div', 'writing-line');
      ['The quick brown fox', 'jumps over', 'the lazy dog.'].forEach((words, index) => {
        const chunk = element('span', 'writing-chunk ' + (index === beat.chunk ? 'is-reading' : index < beat.chunk ? 'written' : 'pending'));
        let position = 0;
        words.split(' ').forEach((word) => {
          const node = element('span', 'writing-word', word + ' ');
          node.dataset.wordStart = String(position);
          position += word.length + 1;
          chunk.appendChild(node);
        });
        line.appendChild(chunk);
        line.appendChild(element('span', '', ' '));
      });
      task.appendChild(line);
    } else if (beat.count) {
      const capture = element('div', 'capture-preview');
      const time = element('div', 'capture-time');
      const count = element('b', 'capture-count', String(beat.count));
      count.dataset.count = '';
      time.appendChild(count);
      time.appendChild(element('span', 'capture-unit', ' seconds'));
      capture.appendChild(time);
      capture.appendChild(element('span', 'capture-label', beat.visual === 'voice' ? 'STEADY “AH”' : 'YOUR USUAL PACE'));
      const wave = element('div', beat.visual === 'voice' ? 'sample-wave' : 'sample-steps');
      for (let i = 0; i < 9; i++) wave.appendChild(element('i'));
      capture.appendChild(wave);
      task.appendChild(capture);
    } else if (beat.image) {
      const preview = element('div', 'photo-preview');
      const img = element('img');
      img.src = '/assets/walkthrough/' + beat.image + '.jpg';
      img.alt = beat.image === 'handwriting-capture' ? 'Complete sentence: The quick brown fox jumps over the lazy dog.' : 'Illustrative captured surroundings photo.';
      preview.appendChild(img);
      preview.appendChild(element('span', 'photo-state', beat.visual === 'photoAccepted' ? '✓ Photo confirmed' : beat.visual === 'description' ? 'Image description' : 'Photo preview'));
      task.appendChild(preview);
      const view = element('button', 'view-photo', 'View full photo ↗');
      view.type = 'button';
      view.addEventListener('click', () => openPhoto(beat));
      task.appendChild(view);
    } else if (beat.visual === 'summary' || beat.visual === 'overview') {
      const list = element('div', 'exam-summary');
      ['Voice sample', 'Handwriting photo', 'Walking observations'].forEach((name) => {
        list.appendChild(element('span', '', (beat.visual === 'summary' ? '✓ ' : '○ ') + name));
      });
      task.appendChild(list);
    } else if (beat.visual === 'caregiver' || beat.visual === 'acknowledged') {
      task.appendChild(element('div', 'notification-state', beat.visual === 'acknowledged' ? '✓ Acknowledged · simulated' : '↗ Care partner update · simulated'));
    } else if (beat.visual === 'rhythm') {
      const rhythm = element('div', 'rhythm-preview');
      for (let i = 0; i < 4; i++) rhythm.appendChild(element('i'));
      task.appendChild(rhythm);
    }
    task.appendChild(element('p', 'task-detail', beat.detail));
  }

  function updatePlaybackControls() {
    for (const chapter of chapters) {
      const selected = playback && playback.chapter === chapter;
      chapter.querySelector('[data-play]').textContent = selected ? playback.playing ? 'Pause this moment Ⅱ' : playback.finished ? 'Replay this moment ↻' : 'Continue this moment ▶' : chapter.id === 'motor' ? 'Watch the guided exam ▶' : 'Play this moment ▶';
      chapter.querySelector('[data-previous]').disabled = !selected || playback.index === 0;
      chapter.querySelector('[data-next]').disabled = Boolean(selected && playback.finished);
      chapter.querySelector('[data-step-count]').textContent = selected ? `${playback.index + 1} / ${journeys[chapter.id].length}` : 'Guided preview';
    }
    $('journeyPlayer').hidden = !(playback && playback.allDay);
    if (playback && playback.allDay) {
      $('journeyLabel').textContent = 'Arun’s day · ' + journeys[playback.chapter.id][playback.index].title;
      $('journeyPause').textContent = playback.playing ? 'Pause' : playback.finished ? 'Replay' : 'Continue';
      $('journeyPrevious').disabled = playback.index === 0;
      $('journeyNext').disabled = playback.finished;
    }
  }

  function clearPlaybackClocks() {
    window.clearTimeout(playbackTimer);
    window.cancelAnimationFrame(playbackFrame);
    silence();
  }

  function pausePlayback() {
    if (!playback || !playback.playing) return;
    ++playbackRevision;
    clearPlaybackClocks();
    playback.playing = false;
    playback.chapter.dataset.running = 'false';
    updatePlaybackControls();
  }

  function stopPlayback() {
    ++playbackRevision;
    clearPlaybackClocks();
    if (playback) {
      delete playback.chapter.dataset.controlled;
      delete playback.chapter.dataset.running;
      delete playback.chapter.dataset.stage;
      delete playback.chapter.dataset.visual;
      playback.chapter.querySelector('.demo-task').hidden = true;
      playback.chapter.querySelector('.beat-progress i').style.transform = 'scaleX(0)';
    }
    playback = null;
    updatePlaybackControls();
    scheduleFrame();
  }

  function tickPlayback(revision) {
    if (!playback || !playback.playing || revision !== playbackRevision) return;
    const beat = journeys[playback.chapter.id][playback.index];
    const remaining = Math.max(0, playback.endAt - performance.now());
    const progress = Math.min(1, Math.max(0, 1 - remaining / beat.duration));
    playback.chapter.querySelector('.beat-progress i').style.transform = `scaleX(${progress})`;
    const count = playback.chapter.querySelector('[data-count]');
    if (count) {
      const seconds = String(Math.ceil(remaining / 1000));
      if (count.textContent !== seconds) count.textContent = seconds;
    }
    playbackFrame = window.requestAnimationFrame(() => tickPlayback(revision));
  }

  function navigateToScene(chapter) {
    const scene = chapter.querySelector('.scene');
    const header = document.querySelector('.nav').getBoundingClientRect();
    const top = Math.max(0, window.scrollY + scene.getBoundingClientRect().top - header.bottom - 16);
    window.scrollTo({top, behavior:reducedMotion.matches ? 'auto' : 'smooth'});
  }

  async function showBeat(chapter, index, auto, allDay = false, navigate = false) {
    const oldChapter = playback && playback.chapter;
    ++playbackRevision;
    clearPlaybackClocks();
    if (oldChapter && oldChapter !== chapter) {
      delete oldChapter.dataset.controlled;
      delete oldChapter.dataset.running;
      delete oldChapter.dataset.stage;
      delete oldChapter.dataset.visual;
      oldChapter.querySelector('.demo-task').hidden = true;
    }
    const revision = playbackRevision;
    const beat = journeys[chapter.id][index];
    playback = {chapter, index, playing:auto, allDay, finished:false, endAt:0};
    chapter.dataset.controlled = 'true';
    chapter.dataset.running = 'false';
    chapter.dataset.stage = String(beat.group);
    chapter.dataset.visual = beat.visual;
    updateMotorScene(chapter, beat);
    chapter.querySelector('.you-said').textContent = beat.user;
    chapter.querySelector('[data-reply]').textContent = beat.reply;
    chapter.querySelector('[data-receipt]').textContent = beat.receipt;
    chapter.querySelectorAll('[data-step]').forEach((step, i) => step.classList.toggle('is-current', i === beat.group));
    chapter.querySelector('.beat-progress i').style.transform = 'scaleX(0)';
    renderTask(chapter, beat);
    updatePlaybackControls();
    // Navigation is explicit: local exam controls never change the scroll position.
    if (navigate) navigateToScene(chapter);
    if (!auto) return;
    // Dictation pauses and capture timers begin only after OS speech ends.
    await narrateGuided(beat.reply, chapter.id + ':guided:' + index, beat.visual === 'writing' ? 0.78 : 0.92);
    if (!playback || revision !== playbackRevision || !playback.playing) return;
    chapter.dataset.running = 'true';
    playback.endAt = performance.now() + beat.duration;
    tickPlayback(revision);
    playbackTimer = window.setTimeout(() => advanceBeat(true), beat.duration);
  }

  function advanceBeat(auto) {
    if (!playback) return;
    const {chapter, index, allDay} = playback;
    if (index + 1 < journeys[chapter.id].length) {
      void showBeat(chapter, index + 1, auto, allDay);
      return;
    }
    ++playbackRevision;
    clearPlaybackClocks();
    playback.playing = false;
    playback.finished = true;
    chapter.dataset.running = 'false';
    chapter.querySelector('.beat-progress i').style.transform = 'scaleX(1)';
    updatePlaybackControls();
    if (auto && allDay) {
      const next = chapters[chapters.indexOf(chapter) + 1];
      if (next) void showBeat(next, 0, true, true, true);
      else {
        stopPlayback();
        $('care').scrollIntoView({behavior:reducedMotion.matches ? 'auto' : 'smooth', block:'start'});
      }
    }
  }

  function narrateGuided(text, key, rate) {
    if (!soundEnabled || !narrationUnlocked || document.hidden) return Promise.resolve();
    const revision = playbackRevision;
    silence();
    lastSpoken = key;
    return new Promise((resolve) => {
      let finished = false;
      let timeout;
      const finish = () => {
        if (finished) return;
        finished = true;
        window.clearTimeout(timeout);
        pendingNarrationDone = null;
        resolve();
      };
      pendingNarrationDone = finish;
      const utterance = new SpeechSynthesisUtterance(text.replace(/[“”]/g, ''));
      utterance.lang = 'en-US';
      utterance.rate = rate;
      utterance.pitch = 1.0;
      const voice = getBestHumanVoice();
      if (voice) utterance.voice = voice;
      utterance.onstart = () => { if (lastSpoken !== key || !soundEnabled) return; narrationUnlocked = true; soundButton.textContent = 'Sound on ◉'; };
      utterance.onend = finish;
      utterance.onerror = event => {
        if (revision === playbackRevision && event.error === 'not-allowed') { narrationUnlocked = false; soundButton.textContent = 'Enable sound ◉'; }
        finish();
      };
      utterance.onboundary = (event) => {
        if (event.name !== 'word' || !playback || finished || revision !== playbackRevision) return;
        const words = playback.chapter.querySelectorAll('.writing-chunk.is-reading .writing-word');
        words.forEach((word, index) => {
          const start = Number(word.dataset.wordStart);
          const end = index + 1 < words.length ? Number(words[index + 1].dataset.wordStart) : Infinity;
          word.classList.toggle('spoken-word', event.charIndex >= start && event.charIndex < end);
        });
      };
      timeout = window.setTimeout(() => { window.speechSynthesis.cancel(); finish(); }, 45000);
      window.speechSynthesis.speak(utterance);
    });
  }

  chapters.forEach((chapter) => {
    chapter.querySelector('[data-play]').addEventListener('click', () => {
      narrationUnlocked = true;
      if (playback && playback.chapter === chapter && playback.playing) pausePlayback();
      else {
        const index = playback && playback.chapter === chapter && !playback.finished ? playback.index : 0;
        void showBeat(chapter, index, true, false);
      }
    });
    chapter.querySelector('[data-next]').addEventListener('click', () => {
      if (playback && playback.chapter === chapter) advanceBeat(false);
      else void showBeat(chapter, 0, false, false);
    });
    chapter.querySelector('[data-previous]').addEventListener('click', () => {
      if (playback && playback.chapter === chapter) void showBeat(chapter, Math.max(0, playback.index - 1), false, false);
    });
  });
  $('playDay').addEventListener('click', () => { narrationUnlocked = true; void showBeat(chapters[0], 0, true, true, true); });
  $('replayDay').addEventListener('click', () => { narrationUnlocked = true; void showBeat(chapters[0], 0, true, true, true); });
  $('journeyPause').addEventListener('click', () => {
    if (!playback) return;
    narrationUnlocked = true;
    if (playback.playing) pausePlayback();
    else void showBeat(playback.chapter, playback.finished ? 0 : playback.index, true, playback.allDay);
  });
  $('journeyStop').addEventListener('click', stopPlayback);
  $('journeyPrevious').addEventListener('click', () => {
    if (playback) void showBeat(playback.chapter, Math.max(0, playback.index - 1), false, playback.allDay);
  });
  $('journeyNext').addEventListener('click', () => {
    if (playback) advanceBeat(playback.playing);
  });
  $('closePhotoViewer').addEventListener('click', () => $('photoViewer').close());
  window.addEventListener('wheel', pausePlayback, {passive:true});
  window.addEventListener('touchstart', (event) => {
    if (!event.target.closest('button')) pausePlayback();
  }, {passive:true});
  window.addEventListener('keydown', (event) => {
    if (['PageDown','PageUp','Home','End','ArrowDown','ArrowUp','Escape'].includes(event.key)) pausePlayback();
  });
  window.addEventListener('pagehide', stopPlayback);
  document.addEventListener('cadence:panelchange', (event) => {
    if (event.detail.panel !== 'build') return;
    pausePlayback();
    silence();
    if ($('photoViewer').open) $('photoViewer').close();
  });

  let judgeBusy = false;
  const liveStatus = $('liveStatus');
  const judgeActions = ['judgeIntent', 'judgeSurroundings', 'judgeWriting', 'judgeVoice'];
  $('judgeLink').addEventListener('click', () => {
    pausePlayback();
    silence();
    $('liveDetails').open = true;
  });

  async function runJudgeAction(action, signal) {
    const response = await fetch('/api/v1/judge-demo/' + action, {
      method: 'POST', signal, redirect: 'error'
    });
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data.detail || data.message || 'The live demo could not finish.');
    }
    return data;
  }

  const judgeRuns = {
    async judgeIntent(signal, report) {
      const intent = await runJudgeAction('intent', signal);
      report(intent.source === 'meta_open_weights'
        ? 'Live intent · ' + intent.intent + ' · ' + intent.model + ' via ' + intent.provider
        : 'Live interpretation was unavailable. Cadence used its local fallback.');
    },

    async judgeSurroundings(signal, report) {
      const photo = await runJudgeAction('surroundings', signal);
      if (!photo.analysis_status) throw new Error('No photo result was returned.');
      const evidence = photo.model_evidence || {};
      const proposal = evidence.proposal || {};
      const segmentation = evidence.segmentation || {};
      report(proposal.source === 'meta_open_weights' && proposal.model
        ? 'Search terms · ' + proposal.model + ' via ' + proposal.provider
        : 'Search terms · preset labels');
      report(segmentation.source === 'meta_model_api' && segmentation.model
        ? 'Segmentation · ' + segmentation.model + ' · ' + photo.analysis_status.replaceAll('_', ' ')
        : 'Live segmentation was unavailable.');
      if (photo.spoken_response) report(photo.spoken_response);
    },

    async judgeWriting(signal, report) {
      let writing = await runJudgeAction('handwriting', signal);
      if (writing.photo_quality?.status === 'unavailable') {
        report('Waiting for Muse. Retrying once…');
        writing = await runJudgeAction('handwriting', signal);
      }
      const quality = writing.photo_quality || {};
      report(quality.model
        ? 'Photo quality · ' + quality.model + ' via ' + quality.provider + ' · ' + quality.status.replaceAll('_', ' ')
        : 'Live handwriting photo review was unavailable.');
      if (quality.advice) report(quality.advice);
    },

    async judgeVoice(signal, report) {
      const voice = await runJudgeAction('voice', signal);
      report(voice.available && voice.transcript
        ? 'Muse Voice Transcribe · “' + voice.transcript + '”'
        : 'Muse Voice Transcribe did not return a transcript.');
    }
  };

  for (const id of judgeActions) {
    const button = $(id);
    button.addEventListener('click', async () => {
      if (judgeBusy) return;
      judgeBusy = true;
      const operation = new AbortController();
      const deadline = window.setTimeout(() => operation.abort(), id === 'judgeWriting' ? 65000 : 35000);
      const results = $(id + 'Results');
      const label = button.textContent;
      button.textContent = 'Running…';
      results.replaceChildren();
      liveStatus.textContent = 'Running selected action…';
      for (const action of judgeActions) $(action).disabled = true;
      const report = message => {
        const item = document.createElement('li');
        item.textContent = message;
        results.appendChild(item);
      };
      try {
        await judgeRuns[id](operation.signal, report);
        liveStatus.textContent = 'Action finished. Choose any tile to run again.';
      } catch (error) {
        report(error.name === 'AbortError' ? 'The request timed out. Try again.' : error.message);
        liveStatus.textContent = 'Action could not finish.';
      } finally {
        window.clearTimeout(deadline);
        button.textContent = label;
        judgeBusy = false;
        for (const action of judgeActions) $(action).disabled = false;
      }
    });
  }
})();
