import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, utimes, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { normalizeQuota, readQuota, resolveCodexPath } from '../src/quota.mjs';

test('aborting a read cancels its dedicated subprocess', async () => {
  const controller = new AbortController();
  const promise = readQuota({codexPath:process.execPath,commandArgs:['-e','setInterval(()=>{},1000)'],signal:controller.signal,timeoutMs:10000});
  setTimeout(()=>controller.abort(),50);
  const result=await promise;
  assert.equal(result.error.code,'cancelled');
});

const now = Date.UTC(2026, 9, 24);
const window = (usedPercent, resetsAt = 1792857600) => ({ usedPercent, windowDurationMins: 10080, resetsAt });

test('prefers multiple buckets over legacy and retains unknown windows as unknown', () => {
  const result = normalizeQuota({ rateLimits: { primary: window(100) }, rateLimitsByLimitId: {
    codex: { limitId: 'codex', primary: window(20), secondary: { usedPercent: null, resetsAt: null } },
    other: { limitId: 'other', limitName: 'Other quota', secondary: window(50), token: 'secret' },
  }, accountId: 'sensitive-id' }, { now });
  assert.equal(result.status, 'ok');
  assert.equal(result.buckets.length, 2);
  assert.equal(result.buckets[0].windows[0].remainingPercent, 80);
  assert.equal(result.buckets[0].windows[1].remainingPercent, null);
  assert.equal(result.buckets[0].windows[1].resetAt, null);
  assert.equal(result.buckets[1].windows[0].remainingPercent, 50);
  assert.ok(!JSON.stringify(result).includes('secret'));
  assert.ok(!JSON.stringify(result).includes('sensitive-id'));
  assert.equal(result.fetchedAt, '2026-10-24T00:00:00.000Z');
});

test('supports legacy, zero usage and overage without false availability', () => {
  const result = normalizeQuota({ rateLimits: { primary: window(0), secondary: window(125) } });
  assert.equal(result.buckets[0].windows[0].remainingPercent, 100);
  assert.equal(result.buckets[0].windows[1].remainingPercent, 0);
  assert.equal(normalizeQuota(null).status, 'unavailable');
  assert.equal(normalizeQuota({ rateLimits: { primary: window('20') } }).status, 'unavailable');
  assert.equal(normalizeQuota({ rateLimits: { primary: window(-5) } }).status, 'unavailable');
});

test('malformed reset values stay null and cannot break rendering', () => {
  for (const value of [null, 'tomorrow', Infinity, -1, 1e100]) {
    assert.equal(normalizeQuota({ rateLimits: { primary: window(15, value) } }).buckets[0].windows[0].resetAt, null);
  }
});

const fixture = (scenario) => ['--input-type=module', '-e', `
import readline from 'node:readline';
const scenario = ${JSON.stringify(scenario)};
let initialized = false;
readline.createInterface({input:process.stdin}).on('line', line => {
  const request = JSON.parse(line);
  if (request.method === 'initialize') {
    if (scenario === 'timeout') return;
    process.stdout.write(JSON.stringify({id:request.id,result:{userAgent:'test'}}) + '\\n');
  } else if (request.method === 'initialized') initialized = true;
  else if (request.method === 'account/rateLimits/read') {
    if (!initialized) process.exit(8);
    if (scenario === 'auth') process.stdout.write(JSON.stringify({id:request.id,error:{code:-1,message:'Unauthorized SECRET_TOKEN'}}) + '\\n');
    else if (scenario === 'error') process.stdout.write(JSON.stringify({id:request.id,error:{code:-1,message:'SECRET_TOKEN internal details'}}) + '\\n');
    else {
      const answer = JSON.stringify({id:request.id,result:{rateLimits:{limitId:'codex',primary:{usedPercent:32,windowDurationMins:300,resetsAt:1792857600}}}}) + '\\n';
      process.stdout.write('diagnostic-not-json\\n' + JSON.stringify({method:'test',params:{}}) + '\\n');
      process.stdout.write(answer.slice(0, 19));
      setTimeout(() => process.stdout.write(answer.slice(19)), 5);
    }
  } else process.exit(9);
});
`];

test('stdio client handshakes before quota read and handles partial lines', async () => {
  const result = await readQuota({ codexPath: process.execPath, commandArgs: fixture('ok') });
  assert.equal(result.status, 'ok');
  assert.equal(result.buckets[0].windows[0].remainingPercent, 68);
});

test('errors never disclose raw service messages and classify login failures', async () => {
  const result = await readQuota({ codexPath: process.execPath, commandArgs: fixture('auth') });
  assert.equal(result.status, 'error');
  assert.equal(result.error.code, 'login_required');
  assert.ok(!JSON.stringify(result).includes('SECRET_TOKEN'));
  const other = await readQuota({ codexPath: process.execPath, commandArgs: fixture('error') });
  assert.equal(other.error.code, 'request_failed');
  assert.ok(!JSON.stringify(other).includes('SECRET_TOKEN'));
});

test('missing executable returns a clear error', async () => {
  const result = await readQuota({ codexPath: 'not-a-real-codex-executable-918235' });
  assert.equal(result.error.code, 'cli_not_found');
});

test('hung child is bounded by timeout', async () => {
  const result = await readQuota({ codexPath: process.execPath, commandArgs: fixture('timeout'), timeoutMs: 150 });
  assert.equal(result.error.code, 'timeout');
});

test('executable override has priority over environment and automatic discovery', async () => {
  assert.equal(await resolveCodexPath({ codexPath: '/explicit/codex', env: { CODEX_QUOTA_CODEX_PATH: '/env/codex' } }), '/explicit/codex');
  assert.equal(await resolveCodexPath({ env: { CODEX_QUOTA_CODEX_PATH: '/env/codex' } }), '/env/codex');
});

test('discovers newest complete Windows version and handles virtualized LOCALAPPDATA', async (t) => {
  const root = await mkdtemp(path.join(tmpdir(), 'quota-resolver-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const userHome = path.join(root, 'user');
  const bin = path.join(userHome, 'AppData', 'Local', 'OpenAI', 'Codex', 'bin');
  for (const [version, mtime] of [['old', 1000], ['current', 2000], ['incomplete', 3000]]) {
    const dir = path.join(bin, version);
    await mkdir(dir, { recursive: true });
    if (version !== 'incomplete') {
      await writeFile(path.join(dir, 'codex.exe'), 'fixture');
      await utimes(path.join(dir, 'codex.exe'), mtime, mtime);
    }
    await utimes(dir, mtime, mtime);
  }
  assert.equal(await resolveCodexPath({ platform: 'win32', env: { LOCALAPPDATA: path.join(root, 'virtual') }, userHome }), path.join(bin, 'current', 'codex.exe'));
  assert.equal(await resolveCodexPath({ platform: 'win32', env: {}, userHome: path.join(root, 'missing') }), 'codex.exe');
  assert.equal(await resolveCodexPath({ platform: 'linux', env: {}, userHome }), 'codex');
});
