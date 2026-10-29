import { readQuota } from './quota.mjs';

// One-shot worker for the floating window. Credentials stay inside Codex.
const controller = new AbortController();
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { if (chunk.trim()) controller.abort(); });
process.stdin.on('end', () => controller.abort());
try {
  const result = await readQuota({ signal: controller.signal, timeoutMs: 20000 });
  process.stdout.write(JSON.stringify(result) + '\n');
} catch {
  process.stdout.write(JSON.stringify({ status: 'error', fetchedAt: new Date().toISOString(), buckets: [], error: { code: 'worker_error', message: '读取额度失败，请稍后刷新。' } }) + '\n');
} finally {
  process.stdin.destroy();
}
