import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const html = readFileSync(new URL('../accounting.html', import.meta.url), 'utf8');
const start = html.indexOf('const requestedCompany=new URLSearchParams(location.search)');
const end = html.indexOf('if(c){', start);
assert(start !== -1 && end !== -1, 'company selection must be present');
const selection = html.slice(start, end);
const companies = [{ id: 'A' }, { id: 'B' }];

async function select(search, saved) {
  const context = {
    URLSearchParams, location: { search }, orgId: 'org',
    localStorage: { getItem: () => saved },
    sb: { from: table => {
      assert.equal(table, 'companies');
      const query = {
        select() { return this; },
        eq() { return this; },
        order: async () => ({ data: companies, error: null }),
      };
      return query;
    } },
  };
  return runInNewContext(`(async()=>{${selection}return c?.id||null})()`, context);
}

assert.equal(await select('?company=B', 'A'), 'B');
assert.equal(await select('', 'B'), 'B');
assert.equal(await select('', 'stale'), 'A');
await assert.rejects(select('?company=foreign', 'A'), /접근할 수 없습니다/);
console.log('Accounting honors the selected company and rejects an inaccessible URL.');
