import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../assets/worklog-sso.js', import.meta.url), 'utf8');

// Fail if a future change reads credentials, intercepts navigation or transmits data.
// The HTML anchor remains responsible for ordinary navigation and separate login.
for (const scenario of ['signed-in', 'signed-out', 'expired', 'unavailable-storage']) {
  const unexpected = name => () => { throw new Error(`${scenario}: unexpected ${name}`); };
  const trap = name => new Proxy({}, { get: unexpected(name), set: unexpected(name) });
  const calls = [];
  const context = {
    localStorage: trap('localStorage access'),
    sessionStorage: trap('sessionStorage access'),
    document: { addEventListener: (...args) => calls.push(args) },
    window: trap('window navigation/access'),
    location: trap('location access'),
    navigator: trap('navigator access'),
    fetch: unexpected('fetch'),
    XMLHttpRequest: unexpected('XMLHttpRequest'),
    WebSocket: unexpected('WebSocket'),
    Image: unexpected('Image'),
  };
  runInNewContext(source, context, { timeout: 1000 });
  assert.equal(calls.length, 0, `${scenario}: must not intercept ordinary links`);
}
console.log('worklog SSO disabled: no credential reads, handlers, or outbound requests');
