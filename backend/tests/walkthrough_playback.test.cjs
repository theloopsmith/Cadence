// Exercise the production controller with virtual time and an inert DOM.
// No browser, network, microphone, provider, or audio device is used.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function setup({allowAutoplay = false, request} = {}) {
  let now = 0, nextId = 1, requests = 0;
  const scrolls = [];
  const timers = new Map(), frames = new Map(), events = new Map();
  class Element {
    constructor() {
      this.dataset = {}; this.style = {}; this.children = []; this.handlers = {};
      this.textContent = ''; this.value = ''; this.hidden = false;
      const classes = new Set();
      this.classList = {add: value => classes.add(value), toggle: (value, enabled) => enabled ? classes.add(value) : classes.delete(value)};
    }
    addEventListener(name, handler) { this.handlers[name] = handler; }
    appendChild(node) { this.children.push(node); return node; }
    replaceChildren(...nodes) { this.children = nodes; }
    setAttribute(name, value) { this[name] = value; }
    scrollIntoView() { this.scrolled = true; }
    showModal() { this.open = true; }
    close() { this.open = false; }
    querySelector(selector) {
      if (selector === '[data-count]') {
        const find = node => Object.hasOwn(node.dataset, 'count') ? node : node.children.map(find).find(Boolean);
        return find(this);
      }
      return null;
    }
  }
  const fields = new Map();
  const get = id => { if (!fields.has(id)) fields.set(id, new Element()); return fields.get(id); };
  const html = fs.readFileSync(path.join(__dirname,'../app/static/walkthrough.html'),'utf8');
  const names = [...html.matchAll(/data-chapter="([^"]+)"/g)].map(match=>match[1]);
  const chapters = names.map((name,index) => {
    const chapter = new Element(); chapter.id = name; chapter.dataset.chapter = name;
    const children = new Map();
    const steps = [new Element(),new Element(),new Element()];
    chapter.querySelector = selector => {
      if (selector === '[data-count]') return chapter.querySelector('.demo-task').querySelector(selector);
      if (!children.has(selector)) {
        const child = new Element();
        if (selector === '.scene') child.getBoundingClientRect = () => ({top:1032 + index*1500 - win.scrollY,height:600});
        children.set(selector,child);
      }
      return children.get(selector);
    };
    chapter.querySelectorAll = () => steps;
    chapter.getBoundingClientRect = () => ({top:1000 + index*1500 - win.scrollY,bottom:2500 + index*1500 - win.scrollY,height:1500});
    return chapter;
  });
  const other = new Map();
  const doc = {
    hidden:false, documentElement:new Element(),
    getElementById:get,
    querySelectorAll:() => chapters,
    querySelector:selector => {
      if (!other.has(selector)) other.set(selector,new Element());
      const result = other.get(selector);
      result.getBoundingClientRect = () => selector === '.nav' ? {top:0,bottom:52,height:52} : {top:60,bottom:1560,height:1500};
      return result;
    },
    createElement:() => new Element(),
    addEventListener:(name,handler) => events.set('document:'+name,handler)
  };
  let firstSpeech = true;
  const speech = {current:null,getVoices:() => [],cancel(){this.current = null;},speak(utterance){if (firstSpeech && !allowAutoplay) {firstSpeech=false;utterance.onerror?.({error:'not-allowed'});return;} firstSpeech=false; this.current = utterance;utterance.onstart?.();}};
  const win = {
    innerHeight:800, speechSynthesis:speech, location:{hash:"#experience"},
    scrollY:0,
    scrollTo(options){scrolls.push(options);this.scrollY=options.top;},
    matchMedia:() => ({matches:false,addEventListener(){}}),
    addEventListener:(name,handler) => events.set('window:'+name,handler),
    setTimeout:(callback,delay) => {const id=nextId++;timers.set(id,{at:now+delay,callback});return id;},
    clearTimeout:id => timers.delete(id),
    requestAnimationFrame:callback => {const id=nextId++;frames.set(id,callback);return id;},
    cancelAnimationFrame:id => frames.delete(id)
  };
  const context = {
    window:win,document:doc,performance:{now:() => now},
    SpeechSynthesisUtterance:class {constructor(text){this.text=text;}},
    AbortController,crypto:{randomUUID:() => 'test-uuid'},
    FileReader: class {
      readAsDataURL() { this.result = 'data:image/jpeg;base64,c2FtcGxl'; this.onload(); }
    },
    fetch:(url, options) => {
      requests++;
      if (request) return request(url, options);
      throw new Error('Unexpected network request');
    }
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../app/static/walkthrough.js'),'utf8'),context);
  const flush = async () => {await Promise.resolve();await Promise.resolve();};
  async function click(element) {await element.handlers.click();await flush();}
  async function advance(ms) {
    const end=now+ms;
    for (;;) {
      const pending=[...timers].filter(([,timer])=>timer.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];
      if (!pending) break;
      now=pending[1].at;timers.delete(pending[0]);pending[1].callback();await flush();
    }
    now=end;
    const callbacks=[...frames.values()];frames.clear();callbacks.forEach(callback=>callback());await flush();
  }
  const motor=chapters.find(chapter=>chapter.id === 'motor');
  return {get,chapters,motor,click,advance,flush,speech,doc,events,scrolls,
    requests:()=>requests,
    step:()=>motor.querySelector('[data-step-count]').textContent,
    async selectMotor(index) {for (let i=0;i<=index;i++) await click(motor.querySelector('[data-next]'));},
    async soundOn(){if (get('soundButton')['aria-pressed'] !== 'true' || get('soundButton').textContent.startsWith('Enable')) await click(get('soundButton'));},
    async mute(){for(let i=0;i<2 && get('soundButton')['aria-pressed'] === 'true';i++) await click(get('soundButton'));},
    async finishSpeech(){assert.ok(speech.current);speech.current.onend();await flush();}
  };
}

test('tour initialization and guided steps do not call the backend',async()=>{
  const env=setup();
  await env.selectMotor(10);
  assert.equal(env.step(),'11 / 11');
  assert.equal(env.requests(),0);
  assert.equal(env.speech.current,null);
});

test('five-second voice timer starts after the spoken Begin completes',async()=>{
  const env=setup();
  await env.selectMotor(2);
  await env.soundOn();
  await env.click(env.motor.querySelector('[data-play]'));
  assert.equal(env.speech.current.text,'Begin.');
  await env.advance(12000);
  assert.equal(env.step(),'3 / 11');
  assert.equal(env.motor.querySelector('[data-count]').textContent,'5');
  await env.finishSpeech();
  await env.advance(4999);
  assert.equal(env.step(),'3 / 11');
  await env.advance(1);
  assert.equal(env.step(),'4 / 11');
});

test('slow dictation gets six full seconds after each phrase finishes',async()=>{
  const env=setup();
  await env.selectMotor(4);
  await env.soundOn();
  await env.click(env.motor.querySelector('[data-play]'));
  assert.equal(env.speech.current.text,'The quick brown fox');
  assert.equal(env.speech.current.rate,0.78);
  await env.advance(9000);
  assert.equal(env.step(),'5 / 11');
  await env.finishSpeech();
  await env.advance(5999);
  assert.equal(env.step(),'5 / 11');
  await env.advance(1);
  assert.equal(env.step(),'6 / 11');
  assert.equal(env.speech.current.text,'jumps over');
});

test('pause and stop fence late speech completion and pending timers',async()=>{
  const env=setup();
  await env.selectMotor(2);
  await env.soundOn();
  await env.click(env.motor.querySelector('[data-play]'));
  const late=env.speech.current;
  await env.click(env.get('journeyPause'));
  late.onend();await env.flush();await env.advance(30000);
  assert.equal(env.step(),'3 / 11');
  assert.equal(env.motor.dataset.running,'false');
  await env.click(env.get('journeyStop'));
  await env.advance(30000);
  assert.equal(env.get('journeyPlayer').hidden,true);
  assert.equal(env.requests(),0);
});

test('hiding the page pauses an active countdown without auto-resuming',async()=>{
  const env=setup();
  await env.selectMotor(9);
  await env.click(env.motor.querySelector('[data-play]'));
  await env.advance(2000);
  env.doc.hidden=true;env.events.get('document:visibilitychange')();
  await env.advance(30000);
  env.doc.hidden=false;env.events.get('document:visibilitychange')();
  assert.equal(env.step(),'10 / 11');
  assert.equal(env.motor.dataset.running,'false');
});

test('whole-day playback finishes on the care view without API or audio calls',async()=>{
  const env=setup();
  await env.mute();
  await env.click(env.get('playDay'));
  await env.advance(300000);
  assert.equal(env.get('journeyPlayer').hidden,true);
  assert.equal(env.get('care').scrolled,true);
  assert.equal(env.requests(),0);
  assert.equal(env.speech.current,null);
});

test('blocked autoplay leaves sound enabled and a Play gesture starts narration',async()=>{
  const env=setup();
  assert.equal(env.get('soundButton')['aria-pressed'],'true');
  assert.equal(env.speech.current,null);
  await env.click(env.motor.querySelector('[data-play]'));
  assert.ok(env.speech.current.text.includes('three short tasks'));
});

test('Play the day navigates to the first scene even with no prior playback',async()=>{
  const env=setup();
  await env.mute();
  await env.click(env.get('playDay'));
  assert.deepEqual(env.chapters.map(chapter=>chapter.id),['motor','medication','walking','surroundings','safety']);
  assert.equal(env.motor.dataset.running,'true');
  assert.equal(env.chapters[1].dataset.running,undefined);
  assert.equal(env.scrolls.length,1);
  assert.equal(env.scrolls[0].top,964); // scene at 1032, minus 52px nav and 16px breathing room
});

test('local guided exam start and subsequent steps never request a scroll',async()=>{
  const env=setup();
  await env.mute();
  await env.click(env.chapters.find(chapter=>chapter.id === 'medication').querySelector('[data-play]'));
  await env.click(env.motor.querySelector('[data-play]'));
  await env.click(env.motor.querySelector('[data-next]'));
  assert.equal(env.scrolls.length,0);
});

test('motor visuals advance through voice, growing handwriting, full photo and walk',async()=>{
  const env=setup();
  await env.selectMotor(1);
  assert.ok(env.motor.querySelector('.scene > img').src.endsWith('/motor-voice.jpg'));
  for (let i=0;i<3;i++) await env.click(env.motor.querySelector('[data-next]'));
  assert.ok(env.motor.querySelector('.scene > img').src.endsWith('/writing-first.jpg'));
  const line=env.motor.querySelector('.demo-task').children.find(child=>child.className==='writing-line');
  assert.equal(line.children.filter(child=>child.className?.includes('is-reading')).length,1);
  await env.click(env.motor.querySelector('[data-next]'));
  assert.ok(env.motor.querySelector('.scene > img').src.endsWith('/writing-second.jpg'));
  await env.click(env.motor.querySelector('[data-next]'));
  await env.click(env.motor.querySelector('[data-next]'));
  assert.ok(env.motor.querySelector('.scene > img').src.endsWith('/handwriting-capture.jpg'));
  await env.click(env.motor.querySelector('[data-next]'));
  await env.click(env.motor.querySelector('[data-next]'));
  assert.ok(env.motor.querySelector('.scene > img').src.endsWith('/hall.jpg'));
});

test('countdown includes a separate seconds unit and photo viewer keeps the complete page',async()=>{
  const env=setup();
  await env.selectMotor(2);
  let task=env.motor.querySelector('.demo-task');
  const capture=task.children.find(child=>child.className==='capture-preview');
  const time=capture.children.find(child=>child.className==='capture-time');
  assert.equal(time.children.map(child=>child.textContent).join(''),'5 seconds');
  for(let i=0;i<5;i++) await env.click(env.motor.querySelector('[data-next]'));
  task=env.motor.querySelector('.demo-task');
  await env.click(task.children.find(child=>child.className==='view-photo'));
  assert.equal(env.get('photoViewer').open,true);
  assert.ok(env.get('photoViewerImage').src.endsWith('/handwriting-capture.jpg'));
  assert.ok(env.get('photoViewerCaption').textContent.includes('The quick brown fox jumps over the lazy dog.'));
  await env.click(env.get('closePhotoViewer'));
  assert.equal(env.get('photoViewer').open,false);
  assert.equal(env.requests(),0);
});

test('opening architecture pauses a guided task and fences future timer callbacks',async()=>{
  const env=setup();
  await env.selectMotor(2);
  await env.mute();
  await env.click(env.motor.querySelector('[data-play]'));
  await env.advance(1000);
  env.events.get('document:cadence:panelchange')({detail:{panel:'build'}});
  await env.advance(30000);
  assert.equal(env.step(),'3 / 11');
  assert.equal(env.motor.dataset.running,'false');
  assert.equal(env.requests(),0);
});


test('welcome plays on load when the browser allows autoplay',async()=>{
  const env=setup({allowAutoplay:true});
  assert.ok(env.speech.current.text.startsWith('Welcome to Cadence'));
  assert.equal(env.get('soundButton').textContent,'Sound on ◉');
});

test('first sound tap unlocks blocked audio instead of muting it',async()=>{
  const env=setup();
  assert.equal(env.get('soundButton').textContent,'Enable sound ◉');
  await env.click(env.get('soundButton'));
  assert.equal(env.get('soundButton')['aria-pressed'],'true');
  assert.ok(env.speech.current);
});

test('layout or programmatic scroll cannot pause the day after Your Rhythm',async()=>{
  const env=setup();
  await env.mute();
  await env.click(env.get('playDay'));
  // Responsive walking layout can leave the viewport center outside the section.
  // Scroll/RAF events must still run repeatedly throughout the whole journey.
  env.chapters[2].getBoundingClientRect = () => ({top:100,bottom:300,height:200});
  for(let i=0;i<70;i++) {
    env.events.get('window:scroll')();
    await env.advance(5000);
  }
  assert.equal(env.get('care').scrolled,true);
  assert.equal(env.chapters[3].querySelector('[data-step-count]').textContent,'Guided preview');
});

test('deliberate wheel scrolling pauses a guided task',async()=>{
  const env=setup();
  await env.mute();
  await env.click(env.get('playDay'));
  env.events.get('window:wheel')();
  await env.advance(300000);
  assert.equal(env.chapters[0].dataset.running,'false');
  assert.notEqual(env.get('care').scrolled,true);
});


test('full-day playback advances from the motor exam into medication next', async () => {
  const env=setup(); await env.mute();
  await env.click(env.get('playDay'));
  for (let i=0; i<11; i++) await env.click(env.get('journeyNext'));
  assert.equal(env.chapters[0].id,'motor');
  assert.equal(env.chapters[0].dataset.running,undefined);
  assert.equal(env.chapters[1].id,'medication');
  assert.equal(env.chapters[1].dataset.running,'true');
  assert.equal(env.get('journeyPlayer').hidden,false);
  assert.equal(env.requests(),0);
});

test('judges run live model requests and verify synthetic records with one click', async () => {
  const calls = [];
  let handwritingAttempts = 0;
  const responses = {
    '/api/v1/auth/login': {role:'device_writer', access_token:'fixture'},
    '/api/v1/device/connection': {patient_id:'hackathon-demo'},
    '/api/v1/companion/interpret': {source:'meta_open_weights', model:'fixture-muse', provider:'baseten', intent:'medication'},
    '/api/v1/reality-check': {
      analysis_status:'identified', spoken_response:'Possible coat rack.',
      model_evidence: {
        proposal:{source:'meta_open_weights', model:'fixture-muse', provider:'baseten'},
        segmentation:{source:'meta_model_api', model:'fixture-sam'}
      }
    },
    '/api/v1/handwriting/analyze': {
      measured:true, spoken_response:'Letter size stayed about the same across the line.',
      photo_quality:{status:'multiple_lines', advice:'Frame just the single line you wrote.', model:'fixture-muse', provider:'baseten'}
    },
    '/api/v1/medication/dose': {},
    '/api/v1/events/fog': {},
    '/api/v1/report/neurologist': {
      medication_logs:[{event_uuid:'walkthrough-test-uuid-dose'}],
      fog_events:[{event_uuid:'walkthrough-test-uuid-walk'}]
    }
  };
  const app = setup({request: async (url, options) => {
    calls.push(url);
    if (url.endsWith('.jpg')) return {ok:true, blob:async () => ({})};
    assert.ok(Object.hasOwn(responses, url));
    if (url === '/api/v1/reality-check') {
      const body = JSON.parse(options.body);
      assert.equal(body.image_base64, 'c2FtcGxl');
      assert.equal(body.simulated_sam_masks, undefined);
      assert.match(body.user_query, /Illustrated judge sample/);
    }
    if (url === '/api/v1/handwriting/analyze') {
      const body = JSON.parse(options.body);
      assert.equal(body.image_base64, 'c2FtcGxl');
      assert.equal(body.check_photo_quality, true);
      assert.equal(body.preview_only, true);
      if (++handwritingAttempts === 1) {
        return {ok:true, json:async () => ({photo_quality:{status:'unavailable'}})};
      }
    }
    return {ok:true, json:async () => responses[url]};
  }});
  await app.click(app.get('judgeLink'));
  assert.equal(app.requests(), 0);
  await app.click(app.get('runSequence'));
  assert.deepEqual(calls, [
    '/api/v1/auth/login', '/api/v1/device/connection', '/api/v1/companion/interpret',
    '/assets/walkthrough/coatstand.jpg', '/api/v1/reality-check',
    '/assets/walkthrough/handwriting-capture.jpg', '/api/v1/handwriting/analyze', '/api/v1/handwriting/analyze',
    '/api/v1/medication/dose', '/api/v1/events/fog', '/api/v1/report/neurologist'
  ]);
  assert.match(app.get('liveStatus').textContent, /Live demo complete/);
  assert.ok(app.get('liveResults').children.some(item => item.textContent.includes('fixture-sam')));
  assert.ok(app.get('liveResults').children.some(item => item.textContent.includes('Handwriting photo quality · fixture-muse')));
});
