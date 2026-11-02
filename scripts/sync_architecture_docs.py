#!/usr/bin/env python3
"""Sync editable architecture labels and a fresh-schema view, without loading secrets.

Run after changing the model configuration, native navigation or database schema.
--check is used by CI. Existing draw.io geometry remains editable.
"""
import argparse
import ast
import html
import json
from pathlib import Path
import re
import sqlite3
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
DRAWIO = ROOT / 'docs/cadence_architecture.drawio'
SCHEMA_SVG = ROOT / 'docs/assets/storage-schema.svg'
SYSTEM_SVG = ROOT / 'docs/assets/system-architecture.svg'


def constant(path, name):
    for node in ast.parse((ROOT / path).read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise ValueError(f'Missing declared constant: {path}:{name}')


def config_defaults():
    tree = ast.parse((ROOT / 'backend/app/config.py').read_text())
    settings = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'Settings')
    wanted = {'meta_sam_model','meta_stt_model','baseten_model','sam_stage_budget_sec',
              'baseten_stage_budget_sec','interactive_request_budget_sec','fall_check_in_sec','inference_requests_per_minute','scene_proposal_budget_sec'}
    def default(node):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'Field':
            node = next(keyword.value for keyword in node.keywords if keyword.arg == 'default')
        return ast.literal_eval(node)
    return {n.target.id: default(n.value) for n in settings.body
            if isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name) and n.target.id in wanted}


def schema_tables():
    # Execute only checked-in DDL against an empty in-memory database. Never
    # import the app, load .env, connect to a patient DB or inspect records.
    with sqlite3.connect(':memory:') as db:
        db.executescript(constant('backend/app/db.py', 'SCHEMA_SQL'))
        db.executescript(constant('backend/app/services/fall_durability.py', 'SCHEMA'))
        tree = ast.parse((ROOT / 'backend/app/db.py').read_text())
        migration = next(n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)
                         and isinstance(n.value, str) and n.value.startswith('CREATE TABLE IF NOT EXISTS schema_migrations'))
        db.execute(migration)
        names = [row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        result = []
        for name in names:
            columns = [(r[1], r[2], bool(r[5])) for r in db.execute(f'PRAGMA table_info("{name}")')]
            foreign = [(r[3], r[2], r[4]) for r in db.execute(f'PRAGMA foreign_key_list("{name}")')]
            result.append((name, columns, foreign))
        return result


def labels(config):
    tabs = re.findall(r'\.tabItem\s*\{\s*Label\("([^"]+)"', (ROOT / 'ios/CadenceCompanion/Views/CadenceRootView.swift').read_text())
    if not tabs: raise ValueError('Native tab labels could not be read')
    pins = json.loads((ROOT / 'ios/App/CadenceCompanionApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
    dat = next(p['state']['version'] for p in pins if p['identity'] == 'meta-wearables-dat-ios')
    return {
        '1 System overview': {
            'c2': '<b>Cadence — current system overview</b><br/>Swift owns immediate assistance and confirmations. FastAPI owns bounded Meta inference, persistence and reports. Public caregiver delivery is simulated.',
            'c3': f'Ray-Ban Meta glasses (Meta Wearables DAT {dat})',
            'c4': 'iPhone — SwiftUI + Meta DAT adapter',
            'c5': 'Backend — FastAPI + SQLite<br/>Cloud HTTPS or local Mac :8001',
            'c7': '<b>Motion adapter</b><br/>Configured 60 Hz accel/gyro/orientation when available; physical acceptance pending.',
            'c13': f'<b>Views</b><br/>{" · ".join(tabs)}. Protection on/off is first. Diary opens from Today; glasses/audio details expand. Help has reserved scroll space. Developer tools stay under the Settings toggle.',
            'c14': '<b>Companion</b><br/>Foreground voice starts by default after OS permission. Context-aware intents, separate confirmations, explicit stop and Hey Meta microphone handoff.',
            'c18': '<b>Medication and diary</b><br/>MedicationPlanEditor owns a stable draft and explicit saved summary. DoseLogModel/retractions and reminders follow the saved plan. MealLogModel persists local photo/note receipts and queues timestamps. DiaryStore/TaskMetrics → PDF.',
            'c27': f'<b>Meta Model API</b><br/>{config["meta_sam_model"]} via /responses; {config["meta_stt_model"]} for optional transcription.',
            'c28': f'<b>Baseten / Meta model</b><br/>{config["baseten_model"]}: allowlisted intent or one exact SAM-grounded label.',
            'c22': '<b>Routes (app/main.py)</b><br/>Auth / scoped events / doses and retractions / meal timestamps / photo and handwriting / transcription / companion intent / exam completion and history / reports / signed Twilio callbacks / website.',
            'c25': '<b>SQLite</b><br/>'+str(len(schema_tables()))+' declared tables. Observation records, scoped accounts, generation/wipe boundaries, retractions and durable alert ledgers. See page 5 for every table and actual SQL foreign key.',
            'c29': '<b>Caregiver transport</b><br/>Twilio SMS/call + signed callbacks in configured deployments. Public demo: simulated only.',
            'c31': 'Installed Apple voices speak Cadence replies. Native Hey Meta conversation is separate; no native Meta TTS or voice invocation is integrated.',
        },
        '2 Fall safety path': {
            'c2': '<b>Fall safety path — separate evidence at every step</b><br/>No model decides escalation. Server recovery continues only after the candidate reaches the backend. Public demo transport is simulated.',
            'c3': 'Available motion<br/>DAT adapter or phone fallback',
            'c12': '<b>Caregiver transport</b><br/>Configured Twilio: SMS/call, DTMF press 1, at-least-once retries. Public demo: visibly simulated.',
            'c7': '<b>DualRecognizerCheckIn</b><br/>Distress from either source latches and escalates. Spoken affirmation is provisional until the window ends; local evidence requires cloud agreement or absence. Cloud alone never cancels. Button cancellation is immediate.',
            'c15': f'<b>Server-owned timeout</b><br/>{config["fall_check_in_sec"]:g} s after candidate ingestion (30 s phone window + grace). A durable recovery sweep resumes unfinished jobs at the current data generation. No server recovery before upload.',
            'c31': 'Still unverified: physical glasses routing, locked-screen continuity and real caregiver delivery. A queued job or provider SID is not human acknowledgment.',
        },
        '3 Meta model calls': {
            'c2': '<b>Meta model calls — bounded inputs, explicit provenance</b><br/>Public startup pins reviewed model IDs; experimental scoring and nutrition inference are removed. Muse proposes search terms; SAM must verify. Service failure and no supported match are distinct; the phone speaks bounded wording.',
            'c4': '<b>POST /reality-check</b><br/>General question: Muse image search terms + living-subject SAM probes run concurrently; SAM then verifies object terms. Named objects skip discovery. At most 6 concepts; no absence/safety claims.',
            'c5': f'<b>{config["meta_sam_model"]}</b><br/>Meta /responses, one named concept per call. Parallel concepts; {config["sam_stage_budget_sec"]:g} s stage, {config["interactive_request_budget_sec"]:g} s shared budget. No free-form scene invention.',
            'c6': '<b>Decode and ground</b><br/>Boxes/masks; missing confidence is not zero. Normal area gate 1.5%. Explicitly requested small objects need confidence ≥0.8 and valid ≥16 px box sides.',
            'c7': f'<b>Exact grounded label → template</b><br/>Muse may choose one complete verified label. Low reasoning, 512 tokens; ≤{config["baseten_stage_budget_sec"]:g} s clamped by remaining budget. Invalid/late output uses deterministic evidence, never an invented label.',
            'c16': f'<b>Muse Voice Transcribe</b><br/>{config["meta_stt_model"]}; multipart audio, text transcript. Installed OS voices provide the spoken reply.',
            'c22': '<b>Everyday companion (foreground)</b><br/>Known requests route locally. Unfamiliar wording: bounded text plus ≤6 recent turns to Meta; no patient facts generated by the model.',
            'c24': f'<b>Muse Spark Open / Baseten</b><br/>{config["baseten_model"]}; low reasoning, JSON allowlisted intent. Response reports provider, requested model ID and latency.',
            'c30': '<b>Evidence and limits</b><br/>Sanitized traces: verification/. Real iPhone/exported glasses photo analysis is distinct from live DAT capture/audio. Deterministic fallback is identified. No raw photo in Git. Per-request HTTP clients remain an open lifecycle improvement.',
        },
        '4 Data and sync': {
            'c3': '<b>Phone profile</b><br/>Documents/CadenceDevice/&lt;uuid&gt;/: diary and task files; pill photos; meal photos/notes (local only); labelled captures; SQLite outbox. Meal receipts stamp the original owner, destination and erase generation. JWT in Keychain.',
            'c5': '<b>Auth and deployment</b><br/>scrypt login budgets; scoped JWTs; account inference quota 30/min + separate check-in transcription quota 60/min (process-local). Static tokens have no built-in values. Public demo: durable secret, static tokens off, simulated transport only, removed experimental scoring and pinned Meta IDs. Caddy HTTPS + one Uvicorn worker.',
            'c9': '<b>Care-team dashboard</b><br/>Nonce CSP + textContent; scoped readers cannot write. Source column distinguishes simulated/device-reported/unverified checks; paired task provenance in typed API responses. Public schema disabled; generation fences writes.',
            'c21': 'Privacy boundaries: inference media is transient. Medication reference photos, meal photos and notes stay local. Logs/metrics persist by owner. Local reset does not erase server rows; server wipe does not erase phone files. Server caregiver routing is deployment-wide.',
            'c22': 'CI: locked backend dependencies, pytest, generated-diagram freshness, dashboard renderer + browser security, tour/math tests, silent Swift tests, and DAT app compilation with the macOS runner’s supported Xcode.',
        },
    }


def table_layout(tables):
    layout = []; top = 115
    for offset in range(0, len(tables), 3):
        row = tables[offset:offset+3]
        tallest = 0
        for column, table in enumerate(row):
            height = 54 + 20*len(table[1])
            layout.append((table, 35+column*450, top, 420, height))
            tallest = max(tallest, height)
        top += tallest+35
    return layout, top+180


def render_schema(tables):
    layout, height = table_layout(tables)
    diagram = ET.Element('diagram', {'id':'cadence-schema','name':'5 Storage schema'})
    model = ET.SubElement(diagram,'mxGraphModel',{'page':'1','pageWidth':'1380','pageHeight':str(height),'grid':'1'})
    root = ET.SubElement(model,'root')
    ET.SubElement(root,'mxCell',{'id':'0'}); ET.SubElement(root,'mxCell',{'id':'1','parent':'0'})
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="1380" height="{height}" style="width:100%;height:auto;display:block" viewBox="0 0 1380 {height}" role="img" aria-labelledby="title desc">',
           '<title id="title">Cadence declared storage schema</title><desc id="desc">Fresh-database tables and actual SQL foreign keys generated from the checked-in DDL. Patient identifiers on observation tables are logical ownership keys, not users-table foreign keys.</desc>',
           f'<rect width="1380" height="{height}" fill="#0c0e0f"/>',
           '<g font-family="Helvetica,Arial,sans-serif" fill="#edf0ef"><text x="35" y="48" font-size="30">Cadence · declared storage schema</text>',
           '<text x="35" y="80" font-size="14" fill="#a6adb0">Generated from db.py + fall_durability.py. PK = primary key; arrows below are actual SQL foreign keys.</text>']
    for (name, columns, foreign), x,y,w,h in layout:
        lines = [('PK ' if pk else '')+col+' : '+kind for col,kind,pk in columns]
        value = '<b>'+html.escape(name)+'</b><br/>'+ '<br/>'.join(html.escape(line) for line in lines)
        cell = ET.SubElement(root,'mxCell',{'id':'schema-'+name,'value':value,'vertex':'1','parent':'1',
            'style':'rounded=1;whiteSpace=wrap;html=1;fillColor=#F0FDF4;strokeColor=#15803D;fontColor=#0F172A;fontSize=13;align=left;verticalAlign=top;spacing=12;'})
        ET.SubElement(cell,'mxGeometry',{'x':str(x),'y':str(y),'width':str(w),'height':str(h),'as':'geometry'})
        svg += [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="#141819" stroke="#465a4e"/>',
                f'<text x="{x+16}" y="{y+29}" font-size="19" fill="#b9edc9">{html.escape(name)}</text>']
        for index,line in enumerate(lines):
            svg.append(f'<text x="{x+16}" y="{y+53+index*20}" font-size="13" font-family="monospace">{html.escape(line)}</text>')
        for index,(column,parent,parent_col) in enumerate(foreign):
            edge=ET.SubElement(root,'mxCell',{'id':f'fk-{name}-{index}','edge':'1','parent':'1','source':'schema-'+name,'target':'schema-'+parent,'value':column+' → '+parent_col,
                'style':'edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=block;strokeColor=#64748B;fontSize=10;labelBackgroundColor=#FFFFFF;'})
            ET.SubElement(edge,'mxGeometry',{'relative':'1','as':'geometry'})
    baseline=height-145
    for name,_,foreign in tables:
        for column,parent,parent_col in foreign:
            svg.append(f'<text x="35" y="{baseline}" font-size="14" fill="#a6adb0">{html.escape(name+"."+column+" → "+parent+"."+parent_col)}</text>')
            baseline += 22
    svg.append('</g></svg>')
    return diagram, '\n'.join(svg)+'\n'



def render_system(config, table_count):
    """Public implementation map, rendered from the same defaults as draw.io."""
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="1020" viewBox="0 0 1280 1020" role="img" aria-labelledby="title desc">',
           '<title id="title">Cadence current implementation architecture</title>',
           '<desc id="desc">Meta glasses feed supported camera, motion and Bluetooth audio to the iPhone. The iPhone owns sensing, confirmations, Apple speech and an account-bound offline queue. Authenticated HTTPS connects it to FastAPI, SQLite, Meta model providers and a read-only dashboard. Public caregiver delivery is simulated; physical capture and audio acceptance are pending.</desc>',
           '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10Z" fill="#92c8ad"/></marker></defs>',
           '<rect width="1280" height="1020" rx="20" fill="#0c0e0f"/>',
           '<g font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">',
           '<text x="32" y="59" font-size="34" font-weight="600" fill="#f5f5f7">Cadence · current implementation</text>',
           '<text x="32" y="96" font-size="16" fill="#abb5b4">Immediate assistance on iPhone. Bounded inference and durable follow-through on the backend.</text>']

    def text(x, y, value, size=16, color='#b6c1be', weight='400'):
        svg.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" font-weight="{weight}">{html.escape(value)}</text>')

    def card(x, y, w, h, kicker, title):
        svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="#151a19" stroke="#3d5149"/>')
        text(x+22,y+31,kicker,12,'#9fcdba','600')
        text(x+22,y+64,title,24,'#edf2ef','600')

    def lines(x, y, values, size=16, step=26):
        for i,value in enumerate(values): text(x,y+i*step,value,size)

    card(32,140,260,270,'INPUT / OUTPUT','Meta glasses')
    lines(54,239,['DAT camera preview + photos','Shutter / wear-state input','Motion adapter when available','Bluetooth microphone + speakers'],15)
    text(54,377,'Physical acceptance pending',13,'#e4c88a')
    card(32,440,260,166,'FALLBACK / TEST INPUT','iPhone + mock kit')
    lines(54,537,['CoreMotion fallback','Labeled synthetic test streams'],15)

    card(326,140,410,466,'SWIFT / SWIFTUI','iPhone app')
    text(348,242,'Companion and guided tasks',18,'#edf2ef','600')
    lines(348,273,['Saved facts + explicit confirmations','Motor check, medication and photo review'])
    text(348,347,'Immediate assistance',18,'#edf2ef','600')
    lines(348,378,['Local motion DSP and walking cues','Deterministic fall check-in / siren','Apple recognition + installed speech voices'])
    text(348,480,'Account-bound local storage',18,'#edf2ef','600')
    lines(348,511,['Diary / photos + durable SQLite outbox','JWT in Keychain; generation-fenced retries'])
    text(348,582,'Foreground conversation; safety takes priority',14,'#9fcdba')

    card(770,140,478,466,'HTTPS / FASTAPI / ONE WORKER','Protected backend')
    text(792,242,'Scoped API',18,'#edf2ef','600')
    lines(792,273,['Writer / reader JWTs; typed response contracts',f'Account inference quota: {config["inference_requests_per_minute"]}/minute',f'Photo pipeline: {config["interactive_request_budget_sec"]:g}-second shared deadline'])
    text(792,376,'Services and recovery',18,'#edf2ef','600')
    lines(792,407,['Grounded photo replies + optional transcription','OpenCV handwriting observations','Durable fall jobs, leases and signed callbacks'])
    text(792,507,'Persistent storage',18,'#edf2ef','600')
    lines(792,538,[f'SQLite · {table_count} declared tables · patient-scoped', 'Caddy HTTPS + persistent Google Cloud VM disk'])

    for x1,y1,x2,y2,both in [(292,280,326,280,False),(292,519,326,519,False),(736,355,770,355,True)]:
        svg.append(f'<path d="M{x1} {y1}L{x2} {y2}" stroke="#92c8ad" stroke-width="2" marker-end="url(#arrow)"'+(' marker-start="url(#arrow)"' if both else '')+'/>')
    svg.append('<path d="M1009 606V638H208V667M580 638V667M1030 638V667" fill="none" stroke="#92c8ad" stroke-width="2"/>')
    card(32,668,350,218,'META MODEL API','Photo + speech input')
    lines(54,768,[config['meta_sam_model'],config['meta_stt_model']],15)
    lines(54,830,['Named-concept masks / boxes','Audio → text; no reply-audio model'],14)
    card(410,668,350,218,'BASETEN / META OPEN WEIGHTS','Constrained interpretation')
    text(432,768,'Muse Spark Open',18,'#edf2ef','600')
    text(432,800,config['baseten_model'],12)
    lines(432,838,['Intent / image search terms / verified label','SAM independently verifies image proposals'],14)
    card(788,668,460,218,'REPORTING / CARE CONNECTION','Evidence before claims')
    lines(810,768,['Read-only dashboard + phone PDF','Queued ≠ provider accepted ≠ acknowledged'],16)
    lines(810,830,['Public demo: caregiver transport simulated','Configured deployments: Twilio + signed callbacks'],14)
    text(32,933,'Public demo excludes research scores, medication-state labels and nutrition advice.',16,'#e4c88a')
    text(32,965,'Glasses routes are implemented adapters; exported-photo proofs do not establish live DAT capture or audible output.',14)
    text(32,991,'Known requests can stay local. Fireworks / Meta Llama 3.3 is a configured alternative when the Baseten key is absent.',14)
    svg.append('</g></svg>')
    return '\n'.join(svg)+'\n'

def outputs():
    tree=ET.parse(DRAWIO); root=tree.getroot()
    for name, cells in labels(config_defaults()).items():
        diagram=next(d for d in root.findall('diagram') if d.get('name') == name)
        for cell_id,value in cells.items():
            cell=diagram.find(f'.//mxCell[@id="{cell_id}"]')
            if cell is None: raise ValueError(f'Missing architecture cell {name}/{cell_id}')
            if cell_id == 'c2':
                title, _, subtitle = value.partition('<br/>')
                value = '<font style="font-size:20px">'+title+'</font><br/><font style="font-size:11px" color="#475569">'+subtitle+'</font>'
            cell.set('value',value)
    for old in list(root.findall('diagram')):
        if old.get('id') == 'cadence-schema': root.remove(old)
    tables = schema_tables()
    schema,svg=render_schema(tables); root.append(schema)
    ET.indent(tree,space='  ')
    return {DRAWIO:ET.tostring(root,encoding='unicode')+'\n', SCHEMA_SVG:svg, SYSTEM_SVG:render_system(config_defaults(), len(tables))}


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--check',action='store_true')
    args=parser.parse_args(); stale=[]
    for path,content in outputs().items():
        if args.check:
            if not path.exists() or path.read_text() != content: stale.append(str(path.relative_to(ROOT)))
        else:
            path.write_text(content)
    if stale: raise SystemExit('Architecture docs are stale; run scripts/sync_architecture_docs.py: '+', '.join(stale))
    print('Architecture diagrams are current.' if args.check else 'Updated editable architecture and generated storage schema.')
