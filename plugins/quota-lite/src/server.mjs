import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readQuota } from './quota.mjs';

export const RESOURCE_URI = 'ui://quota-lite/panel.html';
const PLUGIN_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const INPUT_SCHEMA = { type: 'object', properties: {}, additionalProperties: false };
const ANNOTATIONS = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };

export const TOOLS = [
  {
    name: 'open_quota', title: '额度',
    description: '在应用内打开 Codex 剩余额度面板，显示官方额度窗口、剩余百分比和重置时间。',
    inputSchema: INPUT_SCHEMA, annotations: ANNOTATIONS,
    _meta: {
      ui: { resourceUri: RESOURCE_URI, visibility: ['model', 'app'] },
      'openai/outputTemplate': RESOURCE_URI,
      'openai/widgetAccessible': true,
      'openai/ui': { entrypoints: [{ type: 'global' }, { type: 'thread' }] },
      'openai/toolInvocation/invoking': '正在读取额度',
      'openai/toolInvocation/invoked': '额度已更新'
    }
  },
  {
    name: 'get_quota', title: '刷新额度',
    description: '只读查询当前 Codex 账户的各额度窗口、剩余百分比和重置时间。用于面板刷新或文字回答。',
    inputSchema: INPUT_SCHEMA, annotations: ANNOTATIONS,
    _meta: { ui: { visibility: ['model', 'app'] }, 'openai/widgetAccessible': true }
  }
];

/**
 * Launch the floating widget that ships with this plugin.
 *
 * Two constraints shape this:
 *  1. The widget must NOT live inside Codex's own process tree — Codex starts and stops this
 *     MCP server per plugin load, and tearing that tree down would take the widget with it
 *     (visible as the window flashing and vanishing). Hence WMI (Win32_Process.Create),
 *     which makes WmiPrvSE the parent; the widget shuts itself down once Codex is gone.
 *  2. No console window may flash on every launch. powershell.exe is a console program, so
 *     it is started through wscript.exe + WScript.Shell.Run(..., 0, ...), which is a GUI host
 *     and hides the console it spawns.
 *
 * The widget holds a single-instance mutex, so repeated launches collapse into one window.
 */
export function launchWidget({ pluginRoot = PLUGIN_ROOT } = {}) {
  if (process.env.CODEX_QUOTA_WIDGET === '0') return false;
  if (process.platform !== 'win32') return false;
  const vbs = path.join(pluginRoot, 'widget', 'launch-widget.vbs');
  if (!existsSync(vbs)) return false;
  const quote = (value) => `'${String(value).replace(/'/g, "''")}'`;
  const root = process.env.SystemRoot || 'C:\\Windows';
  const wscript = path.join(root, 'System32', 'wscript.exe');
  const commandLine = `"${wscript}" //nologo "${vbs}"`;
  const launcher = `$startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ WinstationDesktop = 'WinSta0\\Default'; ShowWindow = [uint16]0 }; Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ${quote(commandLine)}; ProcessStartupInformation = $startup } | Out-Null`;
  try {
    // windowsHide 只作用于这个中转进程自己的控制台它不开任何窗口），子链路由 wscript 隐身拉起
    const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command', launcher], {
      stdio: 'ignore',
      windowsHide: true,
    });
    child.on('error', () => {});
    child.unref();
    return true;
  } catch {
    return false;
  }
}

export function makeHandler({ query = readQuota, htmlLoader = () => readFile(new URL('../ui/quota.html', import.meta.url), 'utf8') } = {}) {
  let inFlight = null;
  let last = null;
  async function queryShared() {
    if (last && Date.now() - last.time < 5000) return last.value;
    if (!inFlight) inFlight = Promise.resolve().then(query).then(value => {
      last = { time: Date.now(), value }; return value;
    }).finally(() => { inFlight = null; });
    return inFlight;
  }
  return async function handle(message) {
    const id = message?.id;
    const error = (code, text) => ({ jsonrpc: '2.0', id: id ?? null, error: { code, message: text } });
    if (!message || message.jsonrpc !== '2.0' || typeof message.method !== 'string') return error(-32600, 'Invalid request');
    if (id === undefined) return null;
    let result;
    switch (message.method) {
      case 'initialize':
        result = { protocolVersion: ['2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25'].includes(message.params?.protocolVersion) ? message.params.protocolVersion : '2025-06-18', capabilities: { tools: {}, resources: {}, extensions: { 'io.modelcontextprotocol/ui': { mimeTypes: ['text/html;profile=mcp-app'] } } }, serverInfo: { name: 'quota-lite', title: '额度', version: '1.0.4' } };
        break;
      case 'ping': result = {}; break;
      case 'tools/list': result = { tools: TOOLS }; break;
      case 'resources/list': result = { resources: [{ uri: RESOURCE_URI, name: 'quota-panel', title: '额度', mimeType: 'text/html;profile=mcp-app' }] }; break;
      case 'resources/templates/list': result = { resourceTemplates: [] }; break;
      case 'resources/read':
        if (message.params?.uri !== RESOURCE_URI) return error(-32602, 'Unknown resource');
        result = { contents: [{ uri: RESOURCE_URI, mimeType: 'text/html;profile=mcp-app', text: await htmlLoader(), _meta: { ui: { prefersBorder: true, csp: { connectDomains: [], resourceDomains: [] } }, 'openai/ui': { preferredDisplayMode: 'inline', availableDisplayModes: ['inline', 'fullscreen', 'pip'] }, 'openai/widgetDescription': 'Codex 额度面板，显示剩余百分比和重置时间。' } }] };
        break;
      case 'tools/call': {
        if (!TOOLS.some(tool => tool.name === message.params?.name)) return error(-32602, 'Unknown tool');
        const args = message.params?.arguments ?? {};
        if (!args || typeof args !== 'object' || Array.isArray(args) || Object.keys(args).length) return error(-32602, 'This tool takes no arguments');
        try {
          const data = await queryShared();
          result = { content: [{ type: 'text', text: JSON.stringify(data) }], structuredContent: data, isError: data.status === 'error' };
        } catch {
          const data = { status: 'error', fetchedAt: new Date().toISOString(), buckets: [], error: { code: 'read_failed', message: '读取额度失败，请检查 Codex 登录状态后重试。' } };
          result = { content: [{ type: 'text', text: data.error.message }], structuredContent: data, isError: true };
        }
        break;
      }
      default: return error(-32601, 'Method not found');
    }
    return { jsonrpc: '2.0', id, result };
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  launchWidget();
  const handle = makeHandler();
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  function send(message) { if (message) process.stdout.write(JSON.stringify(message) + '\n'); }
  lines.on('line', async line => {
    if (!line.trim()) return;
    if (line.length > 1048576) { send({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Request too large' } }); return; }
    let message;
    try { message = JSON.parse(line); } catch { send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); return; }
    try { send(await handle(message)); } catch { send({ jsonrpc: '2.0', id: message?.id ?? null, error: { code: -32603, message: 'Internal error' } }); }
  });
}
