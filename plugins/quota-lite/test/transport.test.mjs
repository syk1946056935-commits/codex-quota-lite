import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

test('stdio transport negotiates, lists UI entrypoints and returns valid embedded HTML', async () => {
  const process = spawn(globalThis.process.execPath, [fileURLToPath(new URL('../src/server.mjs', import.meta.url))], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, env: { ...globalThis.process.env, CODEX_QUOTA_WIDGET: '0' } });
  const lines = createInterface({input: process.stdout});
  const pending = new Map(); let id = 0;
  lines.on('line', line => { const result = JSON.parse(line); const waiter = pending.get(result.id); if (waiter) { pending.delete(result.id); waiter(result); } });
  function request(method, params = {}) {
    const callId = ++id;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('transport timeout')), 5000);
      pending.set(callId, reply => { clearTimeout(timeout); resolve(reply); });
      process.stdin.write(JSON.stringify({jsonrpc:'2.0',id:callId,method,params})+'\n');
    });
  }
  try {
    const init = await request('initialize', {protocolVersion:'2025-06-18',capabilities:{},clientInfo:{name:'verification',version:'1'}});
    assert.equal(init.result.serverInfo.name, 'quota-lite');
    process.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
    const listing = await request('tools/list');
    const opener = listing.result.tools.find(tool => tool.name === 'open_quota');
    assert.deepEqual(opener._meta['openai/ui'].entrypoints, [{type:'global'},{type:'thread'}]);
    const resource = await request('resources/read', {uri:opener._meta.ui.resourceUri});
    assert.equal(resource.result.contents[0].mimeType, 'text/html;profile=mcp-app');
    assert.match(resource.result.contents[0].text, /<html/i);
    assert.match(resource.result.contents[0].text, /ui\/initialize/);
    const invalid = await request('tools/call', {name:'get_quota',arguments:{command:'invalid'}});
    assert.equal(invalid.error.code, -32602);
    const unknown = await request('resources/read', {uri:'file:///not-allowed'});
    assert.equal(unknown.error.code, -32602);
  } finally { lines.close(); process.stdin.end(); process.kill(); }
});
