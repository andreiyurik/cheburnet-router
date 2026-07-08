// mock-router.mjs — герметичный стенд для e2e-смоука мастера (playwright).
//
// Раздаёт СОБРАННЫЙ бандл (package/cheburnet/files/web — то, что реально едет в пакет)
// и отвечает на POST /ubus как rpcd с движком: happy-path установки. Реальный
// HTTP/ACL-путь проверяет tests/qemu/webui-v2.sh — здесь проверяем рендер и клики.
//
//   node tests/e2e/mock-router.mjs   # слушает :4317 (запускает playwright webServer)

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join, extname, resolve } from 'node:path';

const PORT = 4317;
const WEB_ROOT = resolve(import.meta.dirname, '../../../package/cheburnet/files/web');
const TOKEN = 'TESTTOKEN';

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png' };

// Состояние «роутера»: до установки → в процессе → установлен.
let installed = false;
let installPolls = 0;
// Режим «health-check не прошёл»: движок откатился, done-маркер fail + reason=health.
// Включается POST /__fail-health — проверка адресной диагностики UI.
let failHealth = false;

const PROVIDERS = [
  { id: 'adguard', name: 'AdGuard DNS', description: 'блокирует рекламу и трекеры' },
  { id: 'adguard-family', name: 'AdGuard Family', description: 'реклама + сайты 18+' },
];

function ubusReply(method, args) {
  switch (method) {
    case 'status':
      return [0, {
        installed,
        wireless_present: true,
        dns_providers: PROVIDERS,
        dns_provider: 'adguard',
        dns_provider_desc: PROVIDERS[0],
        ...(installed && {
          mode: 'home', direct_domains: 1, direct_list_loaded: true, imported_domains: 0,
          awg_handshake_age: 12, dns_up: true, doh_up: true, ssid: 'TestWifi',
        }),
      }];
    case 'check_lan_conflict':
      return [0, { conflict: false }];
    case 'preflight':
      return [0, {
        passed: true, total: 6, failed: 0,
        checks: [
          { id: 'arch', ok: true, detail: 'arch = aarch64' },
          { id: 'ram', ok: true, detail: 'RAM ≈ 485 МБ' },
          { id: 'deps', ok: true, detail: 'зависимости устанавливаются' },
        ],
        tiers: { light: true, full: false },
      }];
    case 'install':
      if (args.token !== TOKEN) return [0, { error: 'неверный install-токен' }];
      installPolls = 0;
      return [0, { started: true }];
    case 'install_progress':
      installPolls += 1;
      if (installPolls < 2) return [0, { done: false, step: 'vpn', log: 'шаг vpn…' }];
      if (failHealth)
        return [0, { done: true, result: 'fail', reason: 'health', step: 'health-check',
                     log: 'install: откат — health-check не пройден\ninstall: откат выполнен' }];
      installed = true;
      return [0, { done: true, result: 'ok', step: 'готово', log: 'установка завершена' }];
    default:
      return [0, {}];
  }
}

createServer(async (req, res) => {
  // Сброс состояния между тестами (spec зовёт в beforeEach) — иначе installed=true
  // от первого прохода утекает во второй и мастер открывает сразу панель.
  if (req.method === 'POST' && req.url === '/__reset') {
    installed = false;
    installPolls = 0;
    failHealth = false;
    res.end('ok');
    return;
  }
  if (req.method === 'POST' && req.url === '/__fail-health') {
    failHealth = true;
    res.end('ok');
    return;
  }
  if (req.method === 'POST' && req.url === '/ubus') {
    let body = '';
    for await (const chunk of req) body += chunk;
    const rpc = JSON.parse(body);
    const [, object, method, args] = rpc.params;
    const result = object === 'cheburnet' ? ubusReply(method, args ?? {}) : [0, {}];
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ jsonrpc: '2.0', id: rpc.id, result }));
    return;
  }

  // Статика: /cheburnet/ → index.html, /cheburnet/assets/* → файлы бандла.
  let path = req.url.split('?')[0];
  if (path === '/cheburnet' || path === '/cheburnet/') path = '/cheburnet/index.html';
  try {
    const data = await readFile(join(WEB_ROOT, path.replace('/cheburnet/', '')));
    res.setHeader('Content-Type', MIME[extname(path)] ?? 'application/octet-stream');
    res.end(data);
  } catch {
    res.statusCode = 404;
    res.end('not found');
  }
}).listen(PORT, () => console.log(`mock-router на http://127.0.0.1:${PORT}/cheburnet/`));
