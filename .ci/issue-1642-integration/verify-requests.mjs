import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
export function verifyRequests(records, expectedCases = 4) {
  if (!Array.isArray(records) || !records.length) throw new Error('Missing transport evidence');
  const cases = new Set();
  for (const record of records) {
    if (!['latest', 'list', 'blocked-download'].includes(record.kind))
      throw new Error('Unexpected protocol activity: ' + record.kind);
    if (typeof record.caseId !== 'string' || !record.caseId || record.method !== 'GET')
      throw new Error('Uncorrelated transport record');
    cases.add(record.caseId);
  }
  if (cases.size !== expectedCases) throw new Error('Wrong observed case count');
  return { transportRecords: records.length, cases: cases.size };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error('Usage: node verify-requests.mjs <requests.ndjson>');
  const records = fs.readFileSync(process.argv[2], 'utf8').split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
  console.log(JSON.stringify(verifyRequests(records)));
}
