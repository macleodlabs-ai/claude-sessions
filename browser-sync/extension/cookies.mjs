// Adapted from Smeagolworms4/claude-switch-account, background.js, MIT.
// Upstream commit 8948a04a334815218a8e1bcc6f6d0c7efa900598.
// Changes: claude.ai-only scope, validation, strict failures and rollback.
export function validDomain(domain) {
  return typeof domain === 'string' && /^(\.)?([a-z0-9-]+\.)*claude\.ai$/.test(domain);
}
export function cookieUrl(cookie) {
  if (!validDomain(cookie.domain) || !cookie.path?.startsWith('/')) throw new Error('Invalid cookie scope');
  return `https://${cookie.domain.replace(/^\./, '')}${cookie.path}`;
}
export function details(cookie) {
  const item = {url: cookieUrl(cookie), name: cookie.name, value: cookie.value,
    path: cookie.path, secure: cookie.secure, httpOnly: cookie.httpOnly, storeId: cookie.storeId};
  if (!cookie.hostOnly) item.domain = cookie.domain;
  if (cookie.sameSite && cookie.sameSite !== 'unspecified') {
    item.sameSite = cookie.sameSite;
    if (cookie.sameSite === 'no_restriction') item.secure = true;
  }
  if (!cookie.session && cookie.expirationDate) item.expirationDate = cookie.expirationDate;
  if (cookie.partitionKey) item.partitionKey = cookie.partitionKey;
  return item;
}
export function validateSnapshot(snapshot, email) {
  if (!snapshot || snapshot.email !== email || !Array.isArray(snapshot.cookies) ||
      !snapshot.cookies.some(c => c.name === 'sessionKey' && c.value)) throw new Error('Saved login does not match');
  for (const c of snapshot.cookies) {
    details(c);
    if (typeof c.name !== 'string' || typeof c.value !== 'string') throw new Error('Invalid cookie');
    if (c.expirationDate && c.expirationDate <= Date.now() / 1000 && c.name === 'sessionKey') {
      throw new Error('Saved login expired');
    }
  }
}
export async function readCookies(api) {
  const cookies = await api.cookies.getAll({domain: 'claude.ai'});
  return cookies.filter(c => validDomain(c.domain));
}
export async function replaceCookies(api, cookies) {
  // Validate before touching the current session.
  cookies.forEach(details);
  for (const c of await readCookies(api)) {
    const removed = await api.cookies.remove({url: cookieUrl(c), name: c.name, storeId: c.storeId,
      ...(c.partitionKey ? {partitionKey: c.partitionKey} : {})});
    if (!removed) throw new Error('Cookie removal failed');
  }
  for (const c of cookies) {
    if (!await api.cookies.set(details(c))) throw new Error('Cookie restore failed');
  }
}
export async function switchCookies(api, snapshot, email, identify) {
  validateSnapshot(snapshot, email);
  const before = await readCookies(api);
  try {
    await replaceCookies(api, snapshot.cookies);
    if (await identify() !== email) throw new Error('Website identity mismatch');
  } catch (error) {
    try { await replaceCookies(api, before); }
    catch { throw new Error('Cookie switch and rollback failed; sign in manually'); }
    throw error;
  }
}
