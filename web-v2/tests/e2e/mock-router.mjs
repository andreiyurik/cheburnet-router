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
// Режим «установлено, но VPN-сервер молчит» (handshake=null) — проверка hero-баннера панели.
let vpnDown = false;
// Full-тир и протокол: панель ветвится по full_capable/full_installed/protocol — сценарии
// выставляют их через POST /__set (JSON с любым подмножеством полей ниже).
let fullCapable = false;
let fullInstalled = false;
let protocol = 'awg';
// Исход фоновых операций панели (install_full_tier / switch_to_reality / replace_*):
// 'ok' | 'fail' — сценарии проверяют и успех, и fail-safe-ветку («прежний туннель возвращён»).
let bgResult = 'ok';
// Текущая фоновая операция панели (не установка мастером): { polls, method }.
let bg = null;
// adminLocked=true — admin-методы без сессии отбиваются кодом 6 (PERMISSION_DENIED), как
// настоящий rpcd ACL; session.login с ADMIN_PASS выдаёт сессию. Проверка модалки входа.
let adminLocked = false;
const ADMIN_PASS = 'panel-pass-1';
const GOOD_SESSION = 'cafecafecafecafecafecafecafecafe';
// Журнал вызовов методов — сценарии ассертят, что панель зовёт ПРАВИЛЬНЫЙ метод
// (replace_reality_conf при protocol=reality, а не replace_awg_conf).
let calls = [];

const ADMIN_METHODS = new Set([
  'set_mode', 'update_list', 'service_restart', 'set_dns_provider',
  'replace_awg_conf', 'replace_reality_conf', 'install_full_tier',
  'switch_to_reality', 'factory_reset',
]);

const PROVIDERS = [
  { id: 'adguard', name: 'AdGuard DNS', description: 'блокирует рекламу и трекеры' },
  { id: 'adguard-family', name: 'AdGuard Family', description: 'реклама + сайты 18+' },
];

function ubusReply(method, args, session) {
  calls.push(method);
  // ACL как у настоящего rpcd: admin-методы без сессии → статус 6 (PERMISSION_DENIED).
  if (adminLocked && ADMIN_METHODS.has(method) && session !== GOOD_SESSION)
    return [6, null];
  switch (method) {
    case 'status':
      return [0, {
        installed,
        wireless_present: true,
        dns_providers: PROVIDERS,
        dns_provider: 'adguard',
        dns_provider_desc: PROVIDERS[0],
        protocol,
        full_capable: fullCapable,
        full_installed: fullInstalled,
        ...((installed || vpnDown) && {
          installed: true,
          mode: 'home', direct_domains: 1, direct_list_loaded: true, imported_domains: 0,
          awg_handshake_age: vpnDown ? null : 12, dns_up: true, doh_up: true, ssid: 'TestWifi',
        }),
      }];
    // Фоновые операции панели: старт → done за 2 поллинга, исход по bgResult.
    case 'install_full_tier':
    case 'switch_to_reality':
    case 'replace_reality_conf':
    case 'replace_awg_conf':
      bg = { polls: 0, method };
      return [0, { status: 'started', pid: 111 }];
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
      // Канал общий с фоновыми операциями панели — они в приоритете, если запущены.
      if (bg) {
        bg.polls += 1;
        if (bg.polls < 2) return [0, { done: false, step: bg.method, log: `${bg.method}…` }];
        const op = bg; bg = null;
        if (bgResult === 'ok') {
          if (op.method === 'install_full_tier') fullInstalled = true;
          if (op.method === 'switch_to_reality') protocol = 'reality';
          return [0, { done: true, result: 'ok', step: 'готово', log: `${op.method}: ok` }];
        }
        return [0, { done: true, result: 'fail', step: op.method, log: `${op.method}: откат — прежнее состояние возвращено` }];
      }
      installPolls += 1;
      if (installPolls < 2) return [0, { done: false, step: 'vpn', log: 'шаг vpn…' }];
      // Ещё один незавершённый тик на шаге health-check — самый долгий (поднятие туннеля).
      // Даёт UI показать усиленный текст предупреждения про обрыв связи именно здесь.
      if (installPolls < 3 && !failHealth)
        return [0, { done: false, step: 'health-check', log: 'проверка связи через туннель…' }];
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
    vpnDown = false;
    fullCapable = false;
    fullInstalled = false;
    protocol = 'awg';
    bgResult = 'ok';
    bg = null;
    adminLocked = false;
    calls = [];
    res.end('ok');
    return;
  }
  // Установить произвольное подмножество состояния (сценарии панели/Full-тира).
  if (req.method === 'POST' && req.url === '/__set') {
    let body = '';
    for await (const chunk of req) body += chunk;
    const st = JSON.parse(body);
    if ('installed' in st) installed = st.installed;
    if ('fullCapable' in st) fullCapable = st.fullCapable;
    if ('fullInstalled' in st) fullInstalled = st.fullInstalled;
    if ('protocol' in st) protocol = st.protocol;
    if ('bgResult' in st) bgResult = st.bgResult;
    if ('adminLocked' in st) adminLocked = st.adminLocked;
    res.end('ok');
    return;
  }
  // Журнал вызванных методов — ассерты «панель позвала правильный метод».
  if (req.method === 'GET' && req.url === '/__calls') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(calls));
    return;
  }
  if (req.method === 'POST' && req.url === '/__fail-health') {
    failHealth = true;
    res.end('ok');
    return;
  }
  if (req.method === 'POST' && req.url === '/__vpn-down') {
    vpnDown = true;
    res.end('ok');
    return;
  }
  if (req.method === 'POST' && req.url === '/ubus') {
    let body = '';
    for await (const chunk of req) body += chunk;
    const rpc = JSON.parse(body);
    const [session, object, method, args] = rpc.params;
    let result;
    if (object === 'cheburnet') {
      result = ubusReply(method, args ?? {}, session);
    } else if (object === 'session' && method === 'login') {
      // Как настоящий rpcd: верный пароль → сессия, неверный → отказ доступа.
      result = (args?.password === ADMIN_PASS)
        ? [0, { ubus_rpc_session: GOOD_SESSION }]
        : [6, null];
    } else {
      result = [0, {}];
    }
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
