import {readCookies, replaceCookies, switchCookies, validateSnapshot, validDomain} from './cookies.mjs';
const HOST = 'ai.macleodlabs.claude_sessions';
let port;
let busy = false;
let owner = null;
let error = '';
const waiting = new Map();
function connect() {
  if (port) return;
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener(msg => {
    const done = waiting.get(msg.id);
    if (done) { waiting.delete(msg.id); done(msg); }
  });
  port.onDisconnect.addListener(() => {
    const message = chrome.runtime.lastError?.message || 'Mac helper disconnected';
    port = null;
    error = message;
    for (const done of waiting.values()) done({ok: false, error: message});
    waiting.clear();
    owner = null;
  });
}
function native(message) {
  connect();
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { waiting.delete(id); reject(new Error('Mac helper timed out')); }, 35000);
    waiting.set(id, msg => {
      clearTimeout(timer);
      if (msg.ok) resolve(msg); else reject(new Error(msg.error));
    });
    port.postMessage({...message, id});
  });
}
async function identify() {
  // Internal web endpoint: fail closed if its response shape changes.
  const response = await fetch('https://claude.ai/api/auth/current_account', {
    credentials: 'include', cache: 'no-store', signal: AbortSignal.timeout(10000)
  });
  if (!response.ok) throw new Error('Cannot verify the Claude website login');
  const data = await response.json();
  const email = data.email_address ?? data.account?.email_address;
  if (typeof email !== 'string' || !email.includes('@')) throw new Error('Website identity unavailable');
  return email.toLowerCase();
}
async function poll() {
  if (busy) return;
  busy = true;
  try {
    owner = (await native({op: 'poll'})).owner;
    if (owner?.phase === 'pending') {
      owner = (await native({op: 'begin', request_id: owner.request_id})).owner;
      try {
        const metadata = (await chrome.storage.local.get('current')).current;
        const currentEmail = await identify().catch(() => null);
        // Never overwrite A's saved session with B's cookies after a manual login.
        if (metadata && metadata.email === currentEmail) {
          // Active-owner saves use a separate operation bounded to the current handoff.
          await native({op: 'snapshot-current', request_id: owner.request_id,
            account: metadata.account, snapshot: {email: currentEmail, cookies: await readCookies(chrome)}});
        }
        const saved = await native({op: 'load', account: owner.mapping.account});
        await switchCookies(chrome, saved.snapshot, owner.mapping.email, identify);
        await chrome.storage.local.set({current: owner.mapping});
        const tabs = await chrome.tabs.query({url: ['https://claude.ai/*', 'https://*.claude.ai/*']});
        await Promise.all(tabs.map(t => chrome.tabs.reload(t.id).catch(() => {})));
        owner = (await native({op: 'prepared', request_id: owner.request_id, email: owner.mapping.email})).owner;
      } catch {
        owner = (await native({op: 'failed', request_id: owner.request_id})).owner;
        error = 'Preparation failed. Re-register the login if needed; release and retry.';
      }
    }
    if (owner?.phase === 'ready') {
      try {
        const email = await identify();
        owner = (await native({op: 'verify-ready', request_id: owner.request_id, email})).owner;
      } catch {
        owner = (await native({op: 'invalidate', request_id: owner.request_id})).owner;
      }
    }
    await chrome.action.setBadgeText({text: owner?.phase === 'ready' ? 'OK' : owner ? '!' : ''});
  } catch (e) { error = e.message; }
  finally { busy = false; }
}
async function action(msg) {
  if (msg.action === 'status') {
    await poll();
    return {owner, error, busy};
  }
  if (busy) throw new Error('Browser sync is busy; retry shortly');
  busy = true;
  try {
    owner = (await native({op: 'poll'})).owner;
    if (msg.action === 'new-login') {
      if (owner) throw new Error('Release browser ownership before adding another login');
      const metadata = (await chrome.storage.local.get('current')).current;
      const email = await identify();
      if (!metadata || metadata.email !== email) throw new Error('Save this login under an alias first');
      await native({op: 'save', account: metadata.account,
        snapshot: {email, cookies: await readCookies(chrome)}});
      // Do not call server logout: it would revoke the saved account's session.
      await replaceCookies(chrome, []);
      await chrome.storage.local.remove('current');
      await chrome.tabs.create({url: 'https://claude.ai/login'});
      return {};
    }
    if (msg.action === 'save') {
      if (owner) throw new Error('Release browser ownership before registering accounts');
      const email = await identify();
      const snapshot = {email, cookies: await readCookies(chrome)};
      validateSnapshot(snapshot, email);
      await native({op: 'save', account: msg.account, snapshot});
      await chrome.storage.local.set({current: {account: msg.account, email}});
      error = '';
      return {email};
    }
    if (msg.action === 'confirm') {
      if (!owner || owner.request_id !== msg.request_id) throw new Error('Handoff changed; refresh the popup');
      const email = await identify();
      if (email !== msg.email.toLowerCase()) throw new Error('Website login changed');
      owner = (await native({op: 'confirm', request_id: owner.request_id, email})).owner;
      error = '';
      return {owner};
    }
    throw new Error('Unknown action');
  } finally { busy = false; }
}
chrome.runtime.onMessage.addListener((msg, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL('popup.html')) return false;
  action(msg).then(data => respond({ok: true, ...data}), e => respond({ok: false, error: e.message}));
  return true;
});
chrome.cookies.onChanged.addListener(change => {
  if (owner?.phase === 'ready' && change.cookie.name === 'sessionKey' && validDomain(change.cookie.domain)) {
    const request_id = owner.request_id;
    owner = {...owner, phase: 'failed'};
    native({op: 'invalidate', request_id}).catch(() => {});
  }
});
chrome.alarms.create('browser-sync', {periodInMinutes: 0.5});
chrome.alarms.onAlarm.addListener(() => { void poll(); });
// A connected native port keeps this worker alive; alarms also recover disconnects.
setInterval(() => { void poll(); }, 2000);
void poll();
