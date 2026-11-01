// Exercise the production controller with virtual time and an inert DOM.
// No browser, network, microphone, provider, or audio device is used.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function setup() {
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
  const names = ['medication','motor','walking','surroundings','safety'];
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
  const speech = {current:null,getVoices:() => [],cancel(){this.current = null;},speak(utterance){this.current = utterance;}};
  const win = {
    innerHeight:800, speechSynthesis:speech,
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
    fetch:() => {requests++;throw new Error('Unexpected network request');}
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
  const motor=chapters[1];
  return {get,chapters,motor,click,advance,flush,speech,doc,events,scrolls,
    requests:()=>requests,
    step:()=>motor.querySelector('[data-step-count]').textContent,
    async selectMotor(index) {for (let i=0;i<=index;i++) await click(motor.querySelector('[data-next]'));},
    async soundOn(){if (get('soundButton')['aria-pressed'] !== 'true') await click(get('soundButton'));},
    async mute(){if (get('soundButton')['aria-pressed'] === 'true') await click(get('soundButton'));},
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

test('sound is enabled by default but no speech occurs before a Play gesture',async()=>{
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
  assert.equal(env.scrolls.length,1);
  assert.equal(env.scrolls[0].top,964); // scene at 1032, minus 52px nav and 16px breathing room
});

test('local guided exam start and subsequent steps never request a scroll',async()=>{
  const env=setup();
  await env.mute();
  await env.click(env.chapters[0].querySelector('[data-play]'));
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
