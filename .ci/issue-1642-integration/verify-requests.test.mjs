import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyRequests } from './verify-requests.mjs';
const records = ['a','b','c','d'].map(caseId => ({ caseId, kind: 'latest', method: 'GET' }));
test('accepts correlated four-case evidence', () => assert.deepEqual(verifyRequests(records), { transportRecords: 4, cases: 4 }));
for (const kind of ['forbidden-connect', 'forbidden-plaintext', 'tls-error']) {
  test('rejects uncorrelated ' + kind, () => assert.throws(() => verifyRequests([...records, { kind }]), /Unexpected protocol/));
}
test('rejects empty evidence', () => assert.throws(() => verifyRequests([]), /Missing/));
test('rejects missing case', () => assert.throws(() => verifyRequests(records.slice(1)), /case count/));
