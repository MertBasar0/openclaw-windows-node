import test from 'node:test';
import assert from 'node:assert/strict';
import { responseFor } from './fixture-proxy.mjs';
const base = '/repos/openclaw/openclaw-windows-node/releases';
const scenario = { latest: { tag_name: 'v1.0.0' }, releases: [{ tag_name: 'v1.0.1-alpha.10' }, { tag_name: 'v1.0.1-alpha.9' }] };
const request = (url, extra = {}) => ({ method: 'GET', url, headers: {}, ...extra });

test('serves pinned latest metadata', () => assert.deepEqual(responseFor(request(base + '/latest'), scenario), { status: 200, kind: 'latest', body: scenario.latest }));
test('preserves unsorted release input', () => assert.deepEqual(responseFor(request(base + '?per_page=30&page=1'), scenario), { status: 200, kind: 'list', body: scenario.releases }));
for (const url of [base + '?page=2', base + '?per_page=100', '/unknown', 'https://example.invalid/anything']) {
  test('rejects unpinned route ' + url, () => assert.equal(responseFor(request(url), scenario).status, 403));
}
test('blocks selected-asset download instead of returning an installable payload', () => assert.deepEqual(responseFor(request('/fixture-assets/test.zip'), scenario), { status: 403, kind: 'blocked-download' }));
for (const headers of [{ authorization: 'synthetic' }, { cookie: 'synthetic' }, { 'proxy-authorization': 'synthetic' }]) {
  test('rejects credential header ' + Object.keys(headers)[0], () => assert.equal(responseFor(request(base, { headers }), scenario).status, 403));
}
test('rejects writes', () => assert.equal(responseFor(request(base, { method: 'POST' }), scenario).status, 403));
