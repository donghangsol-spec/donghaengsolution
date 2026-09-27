import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const html = readFileSync(new URL('../next.html', import.meta.url), 'utf8');
const start = html.indexOf('async function loadAll(){');
const end = html.indexOf('\nfunction renderAll()', start);
assert(start !== -1 && end !== -1, 'loadAll must be present');

const pending = new Map();
const view = { payrollHref: '', accountingHref: '', rows: null, alerts: [] };
const payrollLink = { set href(value) { view.payrollHref = value; } };
const accountingLink = { set href(value) { view.accountingHref = value; } };
const context = {
  companyId: 'A', loadGeneration: 0, employees: [], requests: [], details: [], payrolls: [],
  encodeURIComponent, Promise,
  $: selector => selector === '#payrollDetailLink' ? payrollLink : accountingLink,
  renderAll: () => { view.rows = context.employees.map(row => row.name); },
  alert: message => view.alerts.push(message),
  sb: { from(table) {
    const query = {
      select() { return this; },
      eq(_column, company) { this.company = company; return this; },
      order() { return this; },
      limit() { return this; },
      then(resolve, reject) {
        const key = `${this.company}:${table}`;
        return new Promise((done, fail) => pending.set(key, { done, fail })).then(resolve, reject);
      },
    };
    return query;
  } },
};
runInNewContext(html.slice(start, end), context);

function finish(company) {
  for (const table of ['employees', 'insurance_requests', 'insurance_request_details', 'payroll_periods']) {
    pending.get(`${company}:${table}`).done({ data: table === 'employees' ? [{ name: company }] : [], error: null });
  }
}

const first = context.loadAll();
context.companyId = 'B';
const second = context.loadAll();
await Promise.resolve();
finish('B');
await second;
assert.deepEqual(view.rows, ['B']);
assert.equal(view.payrollHref, './payroll.html?company=B');
assert.equal(view.accountingHref, './accounting.html?company=B');
finish('A');
await first;
assert.deepEqual(view.rows, ['B'], 'late responses must not render the previous company');

context.companyId = null;
await context.loadAll();
assert.deepEqual(Array.from(view.rows), []);
assert.equal(view.payrollHref, './payroll.html');
assert.equal(view.accountingHref, './accounting.html');
assert.deepEqual(view.alerts, []);
console.log('Company switch rejects stale results and clears empty selection.');
