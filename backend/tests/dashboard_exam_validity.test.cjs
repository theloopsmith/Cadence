const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname,'../app/static/dashboard.js'),'utf8');
class Element {
  children = []; _text = ''; style = {}; listeners = {};
  constructor(tag='div') { this.tagName = tag.toUpperCase(); }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this.children.length ? this.children.map(n=>n.textContent).join('') : this._text; }
  get innerHTML() { return ''; }
  set innerHTML(value) { throw Error('HTML parsing sink used: '+value); }
  appendChild(node) { this._text = ''; this.children.push(node); }
  replaceChildren(...nodes) { this._text = ''; this.children = nodes; }
  addEventListener(name, handler) { this.listeners[name] = handler; }
}
function harness(data) {
  const nodes = new Map();
  const doc = {getElementById(id) { if (!nodes.has(id)) nodes.set(id,new Element()); return nodes.get(id); }, createElement(tag) { return new Element(tag); }};
  const storage = new Map([['cadence_bearer_token','test']]);
  const context = vm.createContext({document:doc, URL, window:{addEventListener(){}},
    sessionStorage:{getItem:k=>storage.get(k),removeItem:k=>storage.delete(k)},
    fetch:async()=>({ok:true,status:200,json:async()=>data})});
  vm.runInContext(source,context);
  return {nodes,context,render:()=>vm.runInContext('loadReport()',context)};
}
function baseData() { return {clinical_narrative:'Summary',summary_stats:{dose_count:0,fog_count:0,fall_count:0},fall_events:[],buckets_24h:[],reality_checks:[],medication_logs:[],motor_exams:[]}; }
function descendants(node) { return [node,...node.children.flatMap(descendants)]; }
test('partial checks render missing values and genuine zeros without false comparisons', async () => {
  const data = {clinical_narrative:'Partial check', summary_stats:{dose_count:0,fog_count:0,fall_count:0}, fall_events:[], buckets_24h:[], reality_checks:[], medication_logs:[], motor_exams:[
    {timestamp_utc:'<img src=x onerror=alert(1)>',voice_mean_dbfs:null,voice_stability_db:null,handwriting_opencv_decay_pct:null,walk_cadence_spm:0,walk_fog_count:0},
    {timestamp_utc:'previous',voice_mean_dbfs:-24,voice_stability_db:0,handwriting_opencv_decay_pct:0,walk_cadence_spm:null,walk_fog_count:null}
  ]};
  const {nodes,render} = harness(data);
  await render();
  const rows = nodes.get('examTableBody').children;
  assert.equal(rows.length,2);
  assert.equal(rows[0].children[1].textContent,'Not measured');
  assert.equal(rows[0].children[4].textContent,'0');
  assert.equal(rows[0].children[5].textContent,'0');
  assert.equal(rows[1].children[2].textContent,'0.0');
  assert.equal(rows[0].children[0].textContent,'<img src=x onerror=alert(1)>');
  assert.equal(rows[0].children[0].innerHTML,'');
  assert.match(nodes.get('examDelta').textContent,/Not measured in both checks/);
  assert.doesNotMatch(nodes.get('examDelta').textContent,/NaN/);
});

test('stored markup stays text across every report section', async () => {
  const payload = '<img src=x onerror="fetch(\'/leak\')"><svg onload=alert(1)></svg><script>alert(1)</script>';
  const data = baseData();
  data.clinical_narrative = payload;
  data.fall_events = [{status:payload,timestamp_utc:payload,cancel_transcript:payload,peak_impact_g:3,post_impact_tilt_deg:70,latitude:0,longitude:0}];
  data.reality_checks = [{user_query:payload,spoken_response:payload}];
  data.medication_logs = [{event_type:payload,timestamp_utc:payload,estimated_protein_grams:0,conflict_detected:true}];
  data.buckets_24h = [{label_hhmm:payload,fog_count:1}];
  const {nodes,render} = harness(data);
  await render();
  for (const id of ['narrativeText','fallList','realityList','medList','timelineRibbon']) assert.ok(nodes.get(id).textContent.includes(payload), id);
  const all = [...nodes.values()].flatMap(descendants);
  assert.ok(all.every(node=>!['IMG','SCRIPT','SVG','IFRAME'].includes(node.tagName)));
  const link = all.find(node=>node.tagName==='A');
  assert.equal(link.href,'https://maps.google.com/?q=0%2C0');
  assert.equal(link.rel,'noopener noreferrer');
  assert.equal(link.target,'_blank');
  // Refresh must replace rows, not append or retain previous content.
  data.reality_checks=[]; data.fall_events=[]; data.medication_logs=[];
  await render();
  assert.equal(nodes.get('realityList').children.length,0);
  assert.equal(nodes.get('fallList').children.length,0);
  assert.equal(nodes.get('medList').children.length,0);
});
test('only finite bounded numeric coordinates can create map links', () => {
  const {context} = harness(baseData());
  const map = (lat,lon) => { context.lat=lat;context.lon=lon;return vm.runInContext('safeMapURL(lat,lon)',context); };
  for (const [lat,lon] of [[null,0],[0,null],['0',0],['javascript:alert(1)',0],[NaN,0],[Infinity,0],[91,0],[0,-181]]) assert.equal(map(lat,lon),null);
  assert.equal(map(-90,180),'https://maps.google.com/?q=-90%2C180');
});
test('controls bind listeners without inline handlers and sign-in remains wired', async () => {
  const {nodes,context} = harness(baseData());
  await vm.runInContext('initializeDashboard()',context);
  for (const id of ['seedDemoButton','wipeButton','printButton','fogButton','mealButton','realityButton','writingButton','examButton','fallButton','signInButton']) assert.equal(typeof nodes.get(id).listeners.click,'function');
});

test('writes carry the loaded generation and erase conflicts never retry or render stale reports', async () => {
  const data = baseData(); data.report_metadata = {data_generation:3};
  const {nodes,context,render} = harness(data); await render();
  let count = 0, sent;
  context.fetch = async (url, options) => {
    count++; sent = options.headers;
    return {ok:false,status:409,json:async()=>({error:'data_generation_changed',data_generation:4,message:'Old action was not saved'})};
  };
  await assert.rejects(vm.runInContext('apiPost("/fixture", {})',context),/Old action was not saved/);
  assert.equal(count,1);
  assert.equal(sent['X-Cadence-Data-Generation'],'3');
  data.clinical_narrative = 'stale pre-wipe report';
  context.fetch = async()=>({ok:true,status:200,json:async()=>data});
  await render();
  assert.equal(nodes.get('narrativeText').textContent,'Summary');
});

test('failed wipe does not announce that data was erased', async () => {
  const {nodes,context} = harness(baseData());
  context.fetch = async()=>({ok:false,status:500,json:async()=>({message:'Erase failed'})});
  await assert.rejects(vm.runInContext('wipePatientData()',context),/Erase failed/);
  assert.equal(nodes.get('glassesAudioBanner'),undefined);
});

test('signed-out actions cannot continue into a success announcement', async () => {
  const {context} = harness(baseData());
  vm.runInContext('sessionStorage.removeItem("cadence_bearer_token")',context);
  await assert.rejects(vm.runInContext('apiPost("/fixture", {})',context),/Sign in/);
});

test('report exposes freshness, unknown coverage, truncation and separate contact evidence', async () => {
  const data = baseData();
  data.report_metadata = {window_start_utc:'start',window_end_utc:'end',generated_at_utc:'generated',latest_event_utc:null,coverage_note:'Monitoring coverage unknown.',details_truncated:{fall_events:true}};
  Object.assign(data.summary_stats,{caregiver_provider_accepted_count:2,caregiver_acknowledged_count:1,simulated_alert_count:1});
  data.buckets_24h = [{label_hhmm:'00:00',fog_count:0},{label_hhmm:'00:30',observation_status:'events_logged',fog_count:0}];
  data.fall_events = ['queued','provider_accepted','acknowledged','simulated'].map(contact_state=>({contact_state,status:'dispatched',timestamp_utc:'fixture',peak_impact_g:3,post_impact_tilt_deg:70}));
  const {nodes,render} = harness(data); await render();
  assert.match(nodes.get('reportMetadata').textContent,/start to end.*Generated: generated.*none in this interval.*coverage unknown.*Detail lists are limited/);
  assert.match(nodes.get('contactEvidence').textContent,/Provider accepted: 2.*Caregiver acknowledged: 1.*Simulated delivery: 1/);
  const buckets = nodes.get('timelineRibbon').children;
  assert.match(buckets[0].className,/UNKNOWN/);
  assert.match(buckets[0].textContent,/No observations/);
  assert.match(buckets[1].textContent,/Other logs/);
  const text = nodes.get('fallList').textContent;
  for (const phrase of ['Alert queued; delivery unverified','Alert accepted by provider','Caregiver acknowledged','Simulated delivery']) assert.ok(text.includes(phrase),phrase);
});
