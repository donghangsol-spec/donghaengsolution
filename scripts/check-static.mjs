import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { Script } from 'node:vm';

const files = execFileSync('git', ['ls-files', '-z']).toString().split('\0').filter(Boolean);
let checked = 0;

for (const file of files) {
  if (file.endsWith('.js')) {
    execFileSync(process.execPath, ['--check', file], { stdio: 'inherit' });
    checked++;
  }
  if (!file.endsWith('.html')) continue;
  const html = readFileSync(file, 'utf8');
  const scripts = html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi);
  let index = 0;
  for (const [, attributes, source] of scripts) {
    index++;
    if (/\bsrc\s*=/i.test(attributes) || !source.trim()) continue;
    if (/\btype\s*=\s*["']?(?:application\/json|application\/ld\+json)/i.test(attributes)) continue;
    try {
      new Script(source, { filename: `${file}:script-${index}` });
    } catch (error) {
      console.error(error);
      process.exitCode = 1;
    }
    checked++;
  }
}

const config = JSON.parse(readFileSync('vercel.json', 'utf8'));
if (!config.rewrites?.some(({ source, destination }) => source === '/app' && destination === '/next')) {
  throw new Error('The public /app route must rewrite to /next for Magic Link sign-in.');
}
if (checked === 0) throw new Error('No JavaScript was checked.');
console.log(`Checked ${checked} JavaScript sources and vercel.json.`);
