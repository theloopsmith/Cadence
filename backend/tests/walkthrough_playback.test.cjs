// Exercise the production controller with virtual time and an inert DOM.
// No browser, network, microphone, provider, or audio device is used.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function setup() {
  let now = 0, nextId = 1, selected = -1, requests = 0;
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
      if (!children.has(selector)) children.set(selector,new Element());
      return children.get(selector);
    };
    chapter.querySelectorAll = () => steps;
    chapter.getBoundingClientRect = () => ({top:60 + (index-selected)*1500,bottom:1560 + (index-selected)*1500,height:1500});
    chapter.scrollIntoView = () => {selected = index;};
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
      result.getBoundingClientRect = () => ({top:60,bottom:1560,height:1500});
      return result;
    },
    createElement:() => new Element(),
    addEventListener:(name,handler) => events.set('document:'+name,handler)
  };
  const speech = {current:null,getVoices:() => [],cancel(){this.current = null;},speak(utterance){this.current = utterance;}};
  const win = {
    innerHeight:800, speechSynthesis:speech,
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
  return {get,chapters,motor,click,advance,flush,speech,doc,events,
    requests:()=>requests,
    step:()=>motor.querySelector('[data-step-count]').textContent,
    async selectMotor(index) {for (let i=0;i<=index;i++) await click(motor.querySelector('[data-next]'));},
    async soundOn(){await click(get('soundButton'));},
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
  await env.click(env.get('playDay'));
  await env.advance(300000);
  assert.equal(env.get('journeyPlayer').hidden,true);
  assert.equal(env.get('care').scrolled,true);
  assert.equal(env.requests(),0);
  assert.equal(env.speech.current,null);
});
