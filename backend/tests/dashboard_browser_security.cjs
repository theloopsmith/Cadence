// Isolated browser check. Every request is fulfilled/aborted in memory: no server,
// real token, provider contact, audio playback, or external network is needed.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');

async function main() {
  const shell = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch({headless:true, executablePath:process.env.CADENCE_BROWSER_EXECUTABLE || undefined});
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    const errors = [], violations = [], unexpected = [];
    page.on('pageerror', error=>errors.push(error.message));
    await page.addInitScript(() => {
      sessionStorage.setItem('cadence_bearer_token','isolated-test');
      window.attackExecuted = false;
      window.policyViolations = [];
      document.addEventListener('securitypolicyviolation',e=>window.policyViolations.push(e.effectiveDirective));
    });
    const payload = '<img src=x onerror="window.attackExecuted=true"><svg onload="window.attackExecuted=true"></svg><script>window.attackExecuted=true</script>';
    const data = {clinical_narrative:payload,summary_stats:{dose_count:1,fog_count:0,fall_count:1},
      fall_events:[{timestamp_utc:payload,cancel_transcript:payload,status:'canceled_false_alarm',peak_impact_g:3,post_impact_tilt_deg:70,latitude:0,longitude:0}],
      buckets_24h:[{label_hhmm:payload,fog_count:1}],
      reality_checks:[{user_query:payload,spoken_response:payload}],
      medication_logs:[{timestamp_utc:payload,event_type:payload}],
      motor_exams:[{timestamp_utc:payload,voice_mean_dbfs:null,voice_stability_db:null,handwriting_opencv_decay_pct:null,walk_cadence_spm:0,walk_fog_count:0}]};
    await context.route('**/*', async route => {
      const url = new URL(route.request().url());
      if (url.origin !== 'http://cadence.test') { unexpected.push(url.href); return route.abort(); }
      if (url.pathname === '/dashboard') return route.fulfill({status:200,headers:shell.headers,body:shell.html});
      if (url.pathname === '/assets/dashboard.js' && !url.search) return route.fulfill({status:200,headers:shell.script_headers,body:shell.script});
      if (url.pathname === '/api/v1/report/neurologist') return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(data)});
      unexpected.push(url.href);
      return route.abort();
    });
    await page.goto('http://cadence.test/dashboard');
    await page.waitForFunction(()=>document.getElementById('realityList').textContent.includes('<img'));
    for (const id of ['narrativeText','fallList','timelineRibbon','realityList','medList','examTableBody']) {
      assert.ok((await page.locator('#'+id).textContent()).includes(payload),id);
      assert.equal(await page.locator('#'+id+' img, #'+id+' svg, #'+id+' script').count(),0);
    }
    assert.equal(await page.locator('#fallList a').getAttribute('href'),'https://maps.google.com/?q=0%2C0');
    assert.equal(await page.locator('#examTableBody td').nth(1).textContent(),'Not measured');
    assert.equal(await page.locator('#examTableBody td').nth(4).textContent(),'0');
    // A nonce-authorized external script and addEventListener handlers work.
    await page.evaluate(()=>document.getElementById('authModal').style.display='flex');
    await page.locator('#signInButton').click();
    assert.equal(await page.locator('#loginError').textContent(),'Enter your username and password.');
    assert.equal(await page.evaluate(()=>window.policyViolations.length),0);
    // Even if a future DOM regression inserts markup, CSP blocks executable
    // inline handlers and un-nonced same-origin scripts as defense in depth.
    await page.evaluate(() => {
      const script = document.createElement('script');
      script.textContent = 'window.attackExecuted=true';
      document.body.appendChild(script);
      const external = document.createElement('script');
      external.src = '/assets/dashboard.js?injected';
      document.body.appendChild(external);
      const image = document.createElement('img');
      image.setAttribute('onerror','window.attackExecuted=true');
      document.body.appendChild(image);
      image.dispatchEvent(new Event('error'));
    });
    await page.waitForFunction(()=>window.policyViolations.length>=3);
    assert.equal(await page.evaluate(()=>window.attackExecuted),false);
    assert.deepEqual(errors,[]);
    assert.deepEqual(unexpected,[]);
    violations.push(...await page.evaluate(()=>window.policyViolations));
    console.log(JSON.stringify({result:'passed',stored_markup_inert:true,authorized_script_and_button_work:true,csp_blocked_injected_code:true,unexpected_requests:unexpected.length,policy_violations:violations}));
    await context.close();
  } finally { await browser.close(); }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
