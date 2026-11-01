(function () {
  'use strict';
  const clamp = (number, low, high) => Math.max(low, Math.min(high, number));
  function syntheticSpectrum(balance) {
    const mix = clamp(Number(balance) || 0, 0, 100) / 100;
    return Array.from({length:31}, (_, index) => {
      const frequency = 0.5 + index * 0.25;
      const step = (1.3 - mix) * Math.exp(-Math.pow((frequency - 1.5) / 0.55, 2));
      const higher = (0.05 + mix) * Math.exp(-Math.pow((frequency - 5.2) / 1.05, 2));
      return {frequency, power:step + higher + 0.015};
    });
  }
  function bandRatio(spectrum) {
    let step = 0, higher = 0;
    for (const sample of spectrum) {
      if (sample.frequency >= 0.5 && sample.frequency <= 3) step += sample.power;
      else if (sample.frequency > 3 && sample.frequency <= 8) higher += sample.power;
    }
    return higher / (step + 1e-6);
  }
  function strokeChange(heights) {
    if (heights.length < 4 || heights.some(height => !Number.isFinite(height) || height <= 0)) return null;
    const count = Math.max(2, Math.floor(heights.length / 3));
    const mean = values => values.reduce((sum, value) => sum + value, 0) / values.length;
    const start = mean(heights.slice(0,count));
    const end = mean(heights.slice(-count));
    return {start,end,percent:Math.round((end-start)/start*1000)/10};
  }
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = {syntheticSpectrum,bandRatio,strokeChange};
    return;
  }
  const $ = id => document.getElementById(id);
  const story = $('top'), build = $('buildPanel');
  const tabs = [$('experienceTab'),$('buildTab')];
  if (!story || !build || tabs.some(tab => !tab)) return;
  let panel = 'experience';
  let savedStoryScroll = 0;
  function scrollImmediately(top) {
    const previous = document.documentElement.style.scrollBehavior;
    document.documentElement.style.scrollBehavior = 'auto';
    window.scrollTo({top,behavior:'auto'});
    document.documentElement.style.scrollBehavior = previous;
  }
  function selectPanel(next, updateHash = true) {
    if (next !== 'experience' && next !== 'build') return;
    if (next === 'build' && panel !== 'build') savedStoryScroll = window.scrollY;
    document.dispatchEvent(new CustomEvent('cadence:panelchange',{detail:{panel:next}}));
    story.hidden = next !== 'experience';
    build.hidden = next !== 'build';
    tabs.forEach((tab,index) => {
      const selected = index === (next === 'build' ? 1 : 0);
      tab.setAttribute('aria-selected',String(selected));
      tab.tabIndex = selected ? 0 : -1;
    });
    $('soundButton').hidden = next === 'build';
    panel = next;
    if (updateHash) window.history.replaceState(null,'',next === 'build' ? '#how-it-works' : '#experience');
    scrollImmediately(next === 'build' ? 0 : savedStoryScroll);
  }
  tabs[0].addEventListener('click',() => selectPanel('experience'));
  tabs[1].addEventListener('click',() => selectPanel('build'));
  tabs.forEach((tab,index) => tab.addEventListener('keydown',event => {
    let target = null;
    if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') target = 1-index;
    if (event.key === 'Home') target = 0;
    if (event.key === 'End') target = 1;
    if (target === null) return;
    event.preventDefault();
    selectPanel(target === 0 ? 'experience' : 'build');
    tabs[target].focus();
  }));
  window.addEventListener('hashchange',() => {
    if (window.location.hash === '#how-it-works') selectPanel('build',false);
    else if (panel === 'build') {
      selectPanel('experience',false);
      const target = document.getElementById(window.location.hash.slice(1));
      if (target) target.scrollIntoView({block:'start',behavior:'auto'});
    }
  });
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  function setMotion(still) {
    build.classList.toggle('is-still',still);
    $('buildMotion').setAttribute('aria-pressed',String(still));
    $('buildMotion').disabled = motion.matches;
    $('buildMotion').textContent = motion.matches ? 'Reduced motion enabled' : still ? 'Play animation ▶' : 'Pause animation Ⅱ';
  }
  setMotion(motion.matches);
  $('buildMotion').addEventListener('click',() => setMotion($('buildMotion').getAttribute('aria-pressed') !== 'true'));
  motion.addEventListener('change',event => setMotion(event.matches));

  function renderSpectrum() {
    const spectrum = syntheticSpectrum($('fogBalance').value);
    const max = Math.max(...spectrum.map(sample => sample.power));
    $('spectrumBars').replaceChildren();
    for (const sample of spectrum) {
      const bar = document.createElementNS('http://www.w3.org/2000/svg','rect');
      const height = sample.power/max*160;
      const attrs = {x:70+(sample.frequency-0.5)/7.5*568,y:208-height,width:12,height,rx:2};
      for (const [key,value] of Object.entries(attrs)) bar.setAttribute(key,String(value));
      bar.setAttribute('class','spectrum-bar'+(sample.frequency>3 ? ' high' : ''));
      $('spectrumBars').appendChild(bar);
    }
    $('fogRatio').textContent = bandRatio(spectrum).toFixed(2) + ' ×';
  }
  function renderWriting() {
    const first = 40, last = first*Number($('writingSize').value)/100;
    const heights = [first,first,first,(first*2+last)/3,(first+last)/2,(first+last*2)/3,last,last,last];
    const change = strokeChange(heights);
    $('writingStrokes').replaceChildren();
    heights.forEach(height => {
      const box = document.createElement('span');
      box.style.height = height*1.5+'px';
      $('writingStrokes').appendChild(box);
    });
    $('writingStart').textContent = change.start.toFixed(0)+' px';
    $('writingEnd').textContent = change.end.toFixed(0)+' px';
    $('writingChange').textContent = (change.percent>0 ? '+' : '')+change.percent.toFixed(1)+'%';
    $('writingStrokes').setAttribute('aria-label',`Synthetic component heights. Start ${change.start.toFixed(0)} pixels; end ${change.end.toFixed(0)} pixels. Change ${change.percent.toFixed(1)} percent.`);
  }
  $('fogBalance').addEventListener('input',renderSpectrum);
  $('writingSize').addEventListener('input',renderWriting);
  renderSpectrum();
  renderWriting();
  if (window.location.hash === '#how-it-works') selectPanel('build',false);
})();
