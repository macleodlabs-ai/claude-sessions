let requestId = null;
const el = id => document.getElementById(id);
async function call(message) {
  const result = await chrome.runtime.sendMessage(message);
  if (!result?.ok) throw new Error(result?.error || 'Bridge unavailable');
  return result;
}
async function refresh() {
  const {owner, error} = await call({action: 'status'});
  requestId = owner?.request_id;
  el('status').textContent = owner ? `${owner.mapping.email}\n${owner.phase}\nSession: ${owner.key[1]}` : (error || 'No session owns Chrome.');
  el('confirm-box').hidden = owner?.phase !== 'awaiting-confirmation';
  el('save').disabled = !!owner;
  el('new-login').disabled = !!owner;
}
async function run(fn) {
  try { await fn(); } catch (e) { el('message').textContent = e.message; }
}
el('refresh').onclick = () => run(refresh);
el('save').onclick = () => run(async () => {
  const result = await call({action: 'save', account: el('alias').value.trim()});
  el('message').textContent = `Saved ${result.email}. Bind this alias using the Mac command.`;
});
el('confirm').onclick = () => run(async () => {
  await call({action: 'confirm', request_id: requestId, email: el('email').value.trim()});
  el('message').textContent = 'Confirmed. Retry the browser request in Claude Code.';
  await refresh();
});
void run(refresh);

el('new-login').onclick = () => run(async () => {
  await call({action: 'new-login'});
  el('message').textContent = 'Sign into the next account in the new tab, then save it with a different alias.';
});
