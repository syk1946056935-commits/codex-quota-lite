import { spawn } from 'node:child_process';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

const SOURCE = 'codex-app-server';
const MAX_OUTPUT = 2 * 1024 * 1024;
const ERROR_MESSAGES = Object.freeze({
  cli_not_found: '未找到 Codex，请先安装或打开 Codex 桌面应用。',
  login_required: '请先在 Codex 中登录 ChatGPT 账户，再刷新额度。',
  timeout: '读取额度超时，请稍后刷新。',
  protocol_error: 'Codex 返回了无法读取的数据，请更新 Codex 后重试。',
  request_failed: '暂时无法读取额度，请确认 Codex 已登录并检查网络。',
  process_exit: 'Codex 额度读取进程提前结束，请稍后重试。',
  cancelled: '额度读取已取消。',
});

const record = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const finite = (value) => typeof value === 'number' && Number.isFinite(value);
const label = (value, fallback) => typeof value === 'string' && value.trim()
  ? value.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 120) : fallback;
const timestamp = (value) => {
  if (!finite(value) || value < 0) return null;
  const date = new Date(value * 1000);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
};

function failure(code, now = Date.now()) {
  return { status: 'error', fetchedAt: new Date(now).toISOString(), source: SOURCE,
    buckets: [], error: { code, message: ERROR_MESSAGES[code] ?? ERROR_MESSAGES.request_failed } };
}

/** Resolve the desktop-bundled CLI without executing a shell or relying on its PATH setup. */
export async function resolveCodexPath({
  codexPath,
  env = process.env,
  platform = process.platform,
  userHome = homedir(),
} = {}) {
  if (typeof codexPath === 'string' && codexPath.trim()) return codexPath;
  if (typeof env.CODEX_QUOTA_CODEX_PATH === 'string' && env.CODEX_QUOTA_CODEX_PATH.trim()) {
    return env.CODEX_QUOTA_CODEX_PATH;
  }
  if (platform !== 'win32') return 'codex';
  // LOCALAPPDATA can be virtualized in the Windows sandbox. The user's normal
  // AppData directory remains a separate fallback, without pinning any release.
  const roots = [...new Set([
    env.LOCALAPPDATA,
    userHome ? path.join(userHome, 'AppData', 'Local') : null,
  ].filter((value) => typeof value === 'string' && value))];
  const candidates = [];
  await Promise.all(roots.map(async (root) => {
    const bin = path.join(root, 'OpenAI', 'Codex', 'bin');
    let entries;
    try { entries = await readdir(bin, { withFileTypes: true }); } catch { return; }
    await Promise.all(entries.filter((entry) => entry.isDirectory()).map(async (entry) => {
      const directory = path.join(bin, entry.name);
      const executable = path.join(directory, 'codex.exe');
      try {
        const [fileInfo, directoryInfo] = await Promise.all([stat(executable), stat(directory)]);
        if (fileInfo.isFile()) candidates.push({ path: executable, mtime: Math.max(fileInfo.mtimeMs, directoryInfo.mtimeMs) });
      } catch { /* An incomplete update directory is not an executable candidate. */ }
    }));
  }));
  candidates.sort((a, b) => b.mtime - a.mtime || a.path.localeCompare(b.path));
  return candidates[0]?.path ?? 'codex.exe';
}

/** Whitelist only displayable quota fields. Never return account identifiers, tokens or raw RPC errors. */
export function normalizeQuota(result, { now = Date.now() } = {}) {
  const entries = record(result?.rateLimitsByLimitId)
    ? Object.entries(result.rateLimitsByLimitId).filter(([, value]) => record(value)) : [];
  if (!entries.length && record(result?.rateLimits)) {
    entries.push([label(result.rateLimits.limitId, 'codex'), result.rateLimits]);
  }
  const buckets = entries.map(([key, bucket]) => {
    const id = label(bucket.limitId, label(key, 'codex'));
    const windows = ['primary', 'secondary'].filter((key) => record(bucket[key])).map((key) => {
      const window = bucket[key];
      const usedPercent = finite(window.usedPercent) && window.usedPercent >= 0 ? window.usedPercent : null;
      const resetAt = timestamp(window.resetsAt);
      return {
        id: key,
        usedPercent,
        remainingPercent: usedPercent === null ? null : Math.max(0, Math.min(100, 100 - usedPercent)),
        windowDurationMins: finite(window.windowDurationMins) && window.windowDurationMins > 0
          ? window.windowDurationMins : null,
        resetsAt: resetAt === null ? null : window.resetsAt,
        resetAt,
      };
    });
    return { id, name: label(bucket.limitName, id === 'codex' ? 'Codex' : id),
      planType: typeof bucket.planType === 'string' ? label(bucket.planType, null) : null, windows };
  });
  const available = buckets.some((bucket) => bucket.windows.some((window) => window.usedPercent !== null));
  return { status: available ? 'ok' : 'unavailable', fetchedAt: new Date(now).toISOString(), source: SOURCE,
    buckets, error: available ? null : { code: 'quota_unavailable', message: '当前账户尚未返回可用的额度信息。' } };
}

/**
 * Read the official local app-server's ChatGPT quota method. Creates no thread or model turn.
 * Credentials remain owned by Codex; this module never opens its authentication files.
 * Optional commandArgs is for exercising the stdio protocol against a fixture in tests.
 */
export async function readQuota({
  codexPath,
  timeoutMs = 20000,
  env = process.env,
  commandArgs = ['app-server', '--listen', 'stdio://'],
  signal,
} = {}) {
  const executable = await resolveCodexPath({ codexPath, env });
  return new Promise((resolve) => {
    let child;
    let done = false;
    let buffer = '';
    let received = 0;
    let stage = 'initialize';
    let abortHandler;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (abortHandler) signal?.removeEventListener('abort', abortHandler);
      if (child) {
        child.stdin.destroy();
        child.stdout.destroy();
        child.stderr.destroy();
        // The child is dedicated to this one read and does not host user tasks.
        if (child.exitCode === null) child.kill();
      }
      resolve(value);
    };
    const timer = setTimeout(() => finish(failure('timeout')),
      finite(timeoutMs) && timeoutMs > 0 ? timeoutMs : 20000);
    abortHandler = () => finish(failure('cancelled'));
    signal?.addEventListener('abort', abortHandler, { once: true });
    if (signal?.aborted) { abortHandler(); return; }
    const send = (value) => {
      if (!done && child?.stdin.writable) child.stdin.write(`${JSON.stringify(value)}\n`);
    };
    try {
      child = spawn(executable, commandArgs, { env, shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch {
      finish(failure('cli_not_found'));
      return;
    }
    child.on('error', (error) => finish(failure(error.code === 'ENOENT' ? 'cli_not_found' : 'request_failed')));
    child.on('close', () => finish(failure('process_exit')));
    child.stdin.on('error', () => finish(failure('process_exit')));
    // Drain diagnostics without retaining or exposing arbitrary credential-bearing output.
    child.stderr.on('data', () => {});
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      if (done) return;
      received += Buffer.byteLength(chunk);
      if (received > MAX_OUTPUT) { finish(failure('protocol_error')); return; }
      buffer += chunk;
      let newline;
      while (!done && (newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        if (!record(message)) continue;
        const expectedId = stage === 'initialize' ? 1 : 2;
        if (message.id !== expectedId) continue;
        if (message.error) {
          const description = typeof message.error.message === 'string' ? message.error.message : '';
          const requiresLogin = /not (?:logged|signed) in|unauthori[sz]ed|authentication required|missing.*auth|requires.*chatgpt|not authenticated/i.test(description);
          finish(failure(requiresLogin ? 'login_required' : 'request_failed'));
          return;
        }
        if (!Object.hasOwn(message, 'result')) { finish(failure('protocol_error')); return; }
        if (stage === 'initialize') {
          stage = 'quota';
          send({ method: 'initialized', params: {} });
          send({ id: 2, method: 'account/rateLimits/read' });
        } else {
          finish(normalizeQuota(message.result));
        }
      }
    });
    child.once('spawn', () => send({ id: 1, method: 'initialize', params: {
      clientInfo: { name: 'codex_quota_plugin', title: 'Codex Quota', version: '1.0.0' },
    } }));
  });
}
