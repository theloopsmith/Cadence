const {test} = require('node:test');
const assert = require('node:assert/strict');
const {syntheticSpectrum,bandRatio,strokeChange} = require('../app/static/how-it-works.js');

test('3 Hz belongs to the step band; frequencies outside the two bands are excluded',()=>{
  const ratio=bandRatio([{frequency:0.25,power:100},{frequency:0.5,power:1},{frequency:3,power:3},{frequency:3.25,power:2},{frequency:8,power:2},{frequency:8.25,power:100}]);
  assert.ok(Math.abs(ratio-4/(4+1e-6))<1e-10);
  assert.equal(bandRatio([]),0);
});

test('synthetic example changes the ratio without classifying a clinical event',()=>{
  const low=syntheticSpectrum(0),high=syntheticSpectrum(100);
  assert.ok(high.every(sample=>sample.power>0));
  assert.ok(bandRatio(high)>bandRatio(low));
  assert.ok(Number.isFinite(bandRatio(high)));
});

test('height change uses first and last groups rather than individual extremes',()=>{
  const result=strokeChange([40,40,40,100,3,200,32,32,32]);
  assert.deepEqual(result,{start:40,end:32,percent:-20});
  assert.equal(strokeChange([40,40,40,40]).percent,0);
  assert.equal(strokeChange([40,40,48,48]).percent,20);
});

test('too few or unusable components never become a perfect handwriting result',()=>{
  assert.equal(strokeChange([40,40,40]),null);
  assert.equal(strokeChange([40,0,40,40]),null);
  assert.equal(strokeChange([40,NaN,40,40]),null);
});
