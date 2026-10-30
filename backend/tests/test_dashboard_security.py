import re
from html.parser import HTMLParser
from fastapi.testclient import TestClient
from app.main import app

class Markup(HTMLParser):
    def __init__(self):
        super().__init__(); self.tags=[]
    def handle_starttag(self, tag, attrs): self.tags.append((tag,dict(attrs)))

def test_dashboard_nonce_policy_and_external_script_match_and_do_not_cache():
    http = TestClient(app)
    first,second = http.get('/dashboard'),http.get('/dashboard')
    assert first.status_code==second.status_code==200
    parser = Markup(); parser.feed(first.text)
    scripts = [attrs for tag,attrs in parser.tags if tag=='script']
    assert len(scripts)==1 and scripts[0]['src']=='/assets/dashboard.js'
    nonce = scripts[0]['nonce']
    policy = first.headers['content-security-policy']
    assert f"script-src 'nonce-{nonce}'" in policy
    assert "script-src-attr 'none'" in policy
    assert "object-src 'none'" in policy and "base-uri 'none'" in policy
    assert "frame-ancestors 'none'" in policy and "connect-src 'self'" in policy
    assert 'unsafe-inline' not in policy.split('script-src ',1)[1].split(';',1)[0]
    assert nonce not in second.text and nonce not in second.headers['content-security-policy']
    assert first.headers['cache-control']=='no-store'
    assert first.headers['referrer-policy']=='no-referrer'
    assert first.headers['x-content-type-options']=='nosniff'
    assert not any(key.lower().startswith('on') for _,attrs in parser.tags for key in attrs)
    assert '__CADENCE_SCRIPT_NONCE__' not in first.text

def test_dashboard_asset_is_javascript_and_contains_no_html_parsing_sinks():
    response = TestClient(app).get('/assets/dashboard.js')
    assert response.status_code==200
    assert response.headers['content-type'].startswith('text/javascript')
    assert response.headers['x-content-type-options']=='nosniff'
    for sink in ('innerHTML','outerHTML','insertAdjacentHTML','document.write','eval('):
        assert sink not in response.text
    assert 'textContent' in response.text and 'replaceChildren' in response.text
    assert not re.search(r'new\s+Function\s*\(', response.text)
