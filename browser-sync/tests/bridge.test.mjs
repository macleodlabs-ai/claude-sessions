import test from 'node:test';
import assert from 'node:assert/strict';

// Exercise the actual service worker's Native Messaging request/reply wiring.
test('worker prepares website but requires an explicit matching confirmation', async () => {
  let phase = 'pending';
  const key = ['/config/a', 'session-a'];
  const mapping = {account:'a', email:'a@example.com'};
  const owner = () => ({key, mapping, phase, request_id:'request-1'});
  let receive;
  let handle;
  let jar = [{domain:'claude.ai', name:'sessionKey', value:'old', path:'/',
    secure:true, httpOnly:true, hostOnly:true, storeId:'0', session:true}];
  const ops = [];
  const old = {chrome:globalThis.chrome, fetch:globalThis.fetch, setInterval:globalThis.setInterval};
  globalThis.setInterval = () => 0;
  globalThis.fetch = async () => ({ok:true, json:async () => ({email_address:'a@example.com'})});
  globalThis.chrome = {
    runtime: {
      id:'extension-id', getURL:p => `chrome-extension://extension-id/${p}`,
      connectNative:() => ({
        onMessage:{addListener:fn => {receive=fn;}}, onDisconnect:{addListener:() => {}},
        postMessage:msg => {
          ops.push(msg.op);
          let response = {};
          if (msg.op === 'poll') response = {owner:owner()};
          else if (msg.op === 'begin') {phase='switching'; response={owner:owner()};}
          else if (msg.op === 'load') response = {snapshot:{email:mapping.email, cookies:[{...jar[0], value:'new'}]}};
          else if (msg.op === 'prepared') {phase='awaiting-confirmation'; response={owner:owner()};}
          else if (msg.op === 'confirm') {phase='ready'; response={owner:owner()};}
          else if (msg.op === 'verify-ready') response={owner:owner()};
          else throw new Error(`Unexpected operation ${msg.op}`);
          queueMicrotask(() => receive({id:msg.id, ok:true, ...response}));
        }
      }),
      onMessage:{addListener:fn => {handle=fn;}}
    },
    storage:{local:{get:async () => ({}), set:async () => {}}},
    cookies:{getAll:async () => structuredClone(jar),
      remove:async () => {jar=[]; return {};},
      set:async c => {const v={...c,domain:'claude.ai'};jar.push(v);return v;},
      onChanged:{addListener:() => {}}},
    tabs:{query:async () => [], reload:async () => {}},
    action:{setBadgeText:async () => {}},
    alarms:{create:() => {}, onAlarm:{addListener:() => {}}}
  };
  try {
    await import('../extension/background.js');
    // Drain the asynchronous preparation without any real browser/network access.
    for (let i=0; i<30; i++) await new Promise(resolve => setImmediate(resolve));
    assert.equal(phase, 'awaiting-confirmation');
    assert.equal(jar[0].value, 'new');
    assert.ok(!ops.includes('confirm'));
    const sender = {id:'extension-id',url:'chrome-extension://extension-id/popup.html'};
    const call = msg => new Promise(resolve => handle(msg, sender, resolve));
    const wrong = await call({action:'confirm',request_id:'request-1',email:'wrong@example.com'});
    assert.equal(wrong.ok, false);
    assert.equal(phase, 'awaiting-confirmation');
    const stale = await call({action:'confirm',request_id:'old-request',email:mapping.email});
    assert.equal(stale.ok, false);
    const right = await call({action:'confirm',request_id:'request-1',email:mapping.email});
    assert.equal(right.ok, true);
    assert.equal(phase, 'ready');
    assert.equal(handle({action:'confirm'}, {id:'foreign'}, () => {}), false);
  } finally {
    globalThis.chrome = old.chrome;
    globalThis.fetch = old.fetch;
    globalThis.setInterval = old.setInterval;
  }
});
