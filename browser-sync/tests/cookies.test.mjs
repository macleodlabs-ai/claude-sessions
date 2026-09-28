import test from 'node:test';
import assert from 'node:assert/strict';
import {details, validateSnapshot, switchCookies} from '../extension/cookies.mjs';
const cookie = (value='a') => ({name:'sessionKey', value, domain:'claude.ai', path:'/',
  secure:true, httpOnly:true, hostOnly:true, storeId:'0', session:true, sameSite:'lax'});
function fake() {
  let jar = [cookie()];
  let failOnce = false;
  return {
    get jar() { return jar; },
    fail() { failOnce = true; },
    cookies: {
      getAll: async () => structuredClone(jar),
      remove: async () => { jar = []; return {}; },
      set: async c => {
        if (failOnce) { failOnce = false; throw new Error('restore failed'); }
        const stored = {...c, domain:c.domain || new URL(c.url).hostname};
        jar.push(stored); return stored;
      }
    }
  };
}
test('preserves hostOnly, SameSite and partition properties', () => {
  const c = details({...cookie(), sameSite:'no_restriction', secure:false, partitionKey:{topLevelSite:'https://claude.ai'}});
  assert.equal(c.domain, undefined);
  assert.equal(c.secure, true);
  assert.equal(c.partitionKey.topLevelSite, 'https://claude.ai');
});
test('rejects wrong email, cookie domains and expired login before mutation', async () => {
  for (const snapshot of [
    {email:'other@example.com', cookies:[cookie()]},
    {email:'b@example.com', cookies:[{...cookie(), domain:'claude.ai.attacker.com'}]},
    {email:'b@example.com', cookies:[{...cookie(), expirationDate:1}]}
  ]) {
    const api = fake();
    await assert.rejects(switchCookies(api, snapshot, 'b@example.com', async () => 'b@example.com'));
    assert.equal(api.jar[0].value, 'a');
  }
});
test('restores target and checks resulting identity', async () => {
  const api = fake();
  await switchCookies(api, {email:'b@example.com', cookies:[cookie('b')]}, 'b@example.com', async () => 'b@example.com');
  assert.equal(api.jar[0].value, 'b');
});
test('identity mismatch rolls original cookies back', async () => {
  const api = fake();
  await assert.rejects(switchCookies(api, {email:'b@example.com', cookies:[cookie('b')]}, 'b@example.com', async () => 'wrong@example.com'));
  assert.equal(api.jar[0].value, 'a');
});
test('write failure rolls original cookies back', async () => {
  const api = fake(); api.fail();
  await assert.rejects(switchCookies(api, {email:'b@example.com', cookies:[cookie('b')]}, 'b@example.com', async () => 'b@example.com'));
  assert.equal(api.jar[0].value, 'a');
});
test('rollback failure is surfaced', async () => {
  const api = fake(); api.cookies.set = async () => { throw new Error('fail'); };
  await assert.rejects(switchCookies(api, {email:'b@example.com', cookies:[cookie('b')]}, 'b@example.com', async () => 'b@example.com'), /rollback failed/);
});
