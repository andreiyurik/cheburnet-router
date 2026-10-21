// logic.test.js — юниты чистой логики мастера/панели (vitest, без DOM и сети).
//
//   npm test   (vitest run)
//
// Проверяем границу с пользователем: валидацию формы Setup (validateSetup зеркалит
// ubus-границу движка), карту причин провала установки (explainFail) и разбор конфигов
// для сводки Confirm — то, что раньше жило внутри компонентов и покрывалось только e2e.

import { describe, it, expect } from 'vitest';
import {
  MIN_PASS, SSID_MAX, WIFI_KEY_MIN, WIFI_KEY_MAX,
  parseDomains, validateSetup, explainFail, STEP_LABELS, installPlan,
  endpoint, tunnelSummary, dnsLabel, hs,
  softRisks, canOverride, SOFT_RISK, FORCED_LABELS,
  heroKind, tunnelFallback, switchTargets, tunnelRowText,
  PROTOCOLS, PROTOCOL_ORDER, protocolList, protocolInfo,
  SUPPORT, checkConf,
  moveProfile, lastSwitchText,
} from './logic.js';

// Контакт поддержки показывается на трёх экранах и вшивается в прошивку на годы. Проверяем
// инвариант, который ломается копипастой: ссылка и подпись должны указывать на одного адресата.
describe('SUPPORT — контакт поддержки', () => {
  it('ссылка Telegram соответствует показанному имени', () => {
    expect(SUPPORT.telegram.startsWith('@')).toBe(true);
    expect(SUPPORT.telegramUrl).toBe(`https://t.me/${SUPPORT.telegram.slice(1)}`);
  });
  it('указана долговечная страница проекта — её содержимое правится без перепрошивки', () => {
    expect(SUPPORT.page).toMatch(/^https:\/\//);
  });
  it('ссылка поддержки проекта (футер) — https и вшивается на годы', () => {
    expect(SUPPORT.donateUrl).toMatch(/^https:\/\//);
  });
});

// Валидная база формы: каждый тест ломает ровно одно поле.
function fields(over = {}) {
  return {
    confs: { awg: '[Interface]\nPrivateKey = x\n' },
    rootPass: 'longenough',
    rootPass2: 'longenough',
    showWifi: false,
    wifiRequired: false,
    ssid: '',
    wifiKey: '',
    dnsProvider: '',
    domainsText: 'ru',
    token: 'TOK',
    ...over,
  };
}

describe('parseDomains', () => {
  it('режет по строкам, запятым и пробелам, отбрасывая пустое', () => {
    expect(parseDomains('ru\nexample.com, example.org  test.net')).toEqual([
      'ru', 'example.com', 'example.org', 'test.net',
    ]);
  });

  it('пустой и чисто-пробельный вход → пустой список', () => {
    expect(parseDomains('')).toEqual([]);
    expect(parseDomains('  \n , ,\n')).toEqual([]);
  });
});

// Каталог протоколов — источник соответствия «протокол → поле конфига → ubus-метод» для всего UI.
// Он обязан совпадать с PROTOCOLS движка: разъезд тут = панель зовёт метод не того протокола.
describe('каталог протоколов', () => {
  it('выбирается только AmneziaWG (Full-тир заморожен, ADR 0010)', () => {
    expect(PROTOCOL_ORDER).toEqual(['awg']);
    expect(protocolList().map((p) => p.id)).toEqual(['awg']);
    expect(protocolInfo('bogus').id).toBe('awg');
  });

  // ADR 0009/0010: роутер, оставшийся на Reality/Hysteria2, видит в панели правильное имя, а не «AmneziaWG».
  it('reality и hysteria2 — legacy: имя и Full-признак есть, ни формата, ни методов нет', () => {
    for (const [id, name] of [['reality', 'VLESS+Reality'], ['hysteria2', 'Hysteria2']]) {
      const p = protocolInfo(id);
      expect(p.name).toBe(name);
      expect(p.legacy).toBe(true);
      expect(p.full).toBe(true);
      expect(p.confKey).toBeUndefined();
      expect(p.replaceMethod).toBeUndefined();
    }
  });

  it('у AWG есть объяснение и имена ubus-поля/методов', () => {
    const p = PROTOCOLS.awg;
    expect(p.confKey).toBe('awg_conf');
    expect(p.switchMethod).toBe('switch_to_awg');
    expect(p.replaceMethod).toBe('replace_awg_conf');
  });
});

// Проверка формата ДО отправки. Движок отказал бы и сам, но его отказ стоит цикла «установка →
// откат» (в панели — с фоновой операцией и снимком). Ссылка, вставленная вместо .conf, — самая
// частая путаница, потому что оба поля выглядят одинаково.
describe('checkConf — формат конфига ловится в форме', () => {
  it('пусто → просьба вставить или загрузить файлом', () => {
    expect(checkConf('awg', '   ')).toMatch(/загрузите/i);
  });

  it('правильный .conf проходит; ссылка вместо него — отказ с подсказкой', () => {
    expect(checkConf('awg', '[Interface]\nPrivateKey = x')).toBe('');
    expect(checkConf('awg', 'vless://u@h:443')).toMatch(/\[Interface\]/);
  });

  // Обрезанный конфиг — вторая частая беда: человек копирует со второй строки.
  it('конфиг без шапки [Interface] не принимается', () => {
    expect(checkConf('awg', 'PrivateKey = x\nAddress = 10.0.0.2/32')).toMatch(/\[Interface\]/);
  });
});

describe('validateSetup — конфиг туннеля', () => {
  it('ссылка вместо .conf ловится до отправки (иначе цикл установка → откат)', () => {
    const r = validateSetup(fields({ confs: { awg: 'vless://u@h:443' } }));
    expect(r.error).toMatch(/\[Interface\]/);
    expect(r.args).toBeUndefined();
  });

  it('awg: пустой конфиг → просьба вставить/загрузить', () => {
    const r = validateSetup(fields({ confs: { awg: '   ' } }));
    expect(r.error).toMatch(/загрузите/i);
  });

  it('в args уходит protocol=awg и awg_conf — другого туннеля мастер не ставит', () => {
    const r = validateSetup(fields());
    expect(r.args.protocol).toBe('awg');
    expect(r.args.awg_conf).toBe('[Interface]\nPrivateKey = x');
  });
});

describe('validateSetup — пароль роутера', () => {
  it(`короче ${MIN_PASS} → ошибка с минимумом`, () => {
    const r = validateSetup(fields({ rootPass: '1234567', rootPass2: '1234567' }));
    expect(r.error).toContain(String(MIN_PASS));
  });

  it('пароль не обрезается: пробелы значимы и в длине, и в сравнении', () => {
    // 8 символов с ведущим пробелом — валиден как есть.
    const ok = validateSetup(fields({ rootPass: ' 1234567', rootPass2: ' 1234567' }));
    expect(ok.error).toBeUndefined();
    expect(ok.args.root_password).toBe(' 1234567');
    // Расхождение только в пробеле → «не совпадают».
    const bad = validateSetup(fields({ rootPass: 'longenough', rootPass2: 'longenough ' }));
    expect(bad.error).toMatch(/не совпадают/);
  });
});

describe('validateSetup — Wi-Fi', () => {
  it('секция скрыта (нет радио) → поля игнорируются даже заполненные', () => {
    const r = validateSetup(fields({ showWifi: false, ssid: 'X', wifiKey: 'short' }));
    expect(r.error).toBeUndefined();
    expect(r.args.ssid).toBeUndefined();
  });

  it('необязательный и пустой → в args не попадает', () => {
    const r = validateSetup(fields({ showWifi: true, wifiRequired: false }));
    expect(r.error).toBeUndefined();
    expect(r.args.ssid).toBeUndefined();
    expect(r.args.wifi_key).toBeUndefined();
  });

  it('обязательный (радио точно есть) и пустой → ошибка про SSID', () => {
    const r = validateSetup(fields({ showWifi: true, wifiRequired: true }));
    expect(r.error).toMatch(/SSID/);
  });

  it('необязательный, но начатый → валидируется целиком (ключ короче минимума)', () => {
    const r = validateSetup(fields({ showWifi: true, ssid: 'MyHome', wifiKey: '1234567' }));
    expect(r.error).toContain(String(WIFI_KEY_MIN));
  });

  it('SSID длиннее лимита → ошибка', () => {
    const r = validateSetup(fields({
      showWifi: true, ssid: 'x'.repeat(SSID_MAX + 1), wifiKey: 'goodkey123',
    }));
    expect(r.error).toContain(String(SSID_MAX));
  });

  it('ключ длиннее WPA-максимума → ошибка', () => {
    const r = validateSetup(fields({
      showWifi: true, ssid: 'MyHome', wifiKey: 'x'.repeat(WIFI_KEY_MAX + 1),
    }));
    expect(r.error).toContain(String(WIFI_KEY_MAX));
  });

  it('SSID обрезается, ключ — нет (значимые пробелы)', () => {
    const r = validateSetup(fields({ showWifi: true, ssid: ' MyHome ', wifiKey: ' pass1234' }));
    expect(r.error).toBeUndefined();
    expect(r.args.ssid).toBe('MyHome');
    expect(r.args.wifi_key).toBe(' pass1234');
  });
});

describe('validateSetup — токен и сборка args', () => {
  it('пустой токен → ошибка про код установки', () => {
    const r = validateSetup(fields({ token: '  ' }));
    expect(r.error).toMatch(/код установки/i);
  });

  it('полный happy-path: домены разобраны, токен обрезан, провайдер попал в args', () => {
    const r = validateSetup(fields({
      dnsProvider: 'adguard', domainsText: 'ru, example.com', token: ' TOK ',
    }));
    expect(r.error).toBeUndefined();
    expect(r.args).toEqual({
      protocol: 'awg',
      // Конфиг обрезается по краям: хвостовой перевод строки от копипасты значения не несёт.
      awg_conf: '[Interface]\nPrivateKey = x',
      root_password: 'longenough',
      dns_provider: 'adguard',
      domains: ['ru', 'example.com'],
      token: 'TOK',
    });
  });

  it('без dnsProvider ключ dns_provider не подмешивается (движок возьмёт дефолт)', () => {
    const r = validateSetup(fields());
    expect('dns_provider' in r.args).toBe(false);
  });

  it('acceptRisk доезжает до args (иначе движок откажет на своём preflight)', () => {
    expect(validateSetup(fields({ acceptRisk: true })).args.accept_risk).toBe(true);
  });

  it('без acceptRisk ключа нет вовсе — риск не должен «включаться» молча', () => {
    expect('accept_risk' in validateSetup(fields()).args).toBe(false);
    expect('accept_risk' in validateSetup(fields({ acceptRisk: false })).args).toBe(false);
  });
});

// Пропуск проверок железа: решение принимает движок (overridable), UI лишь объясняет.
describe('softRisks / canOverride — установка на слабом железе', () => {
  const report = (over = {}) => ({
    passed: false, failed: 1, total: 6, hard_failed: 0, soft_failed: 1, overridable: true,
    checks: [
      { id: 'arch', ok: true, severity: 'hard', detail: 'arch = mips' },
      { id: 'flash', ok: false, severity: 'soft', detail: 'свободный флеш ≈ 12 МБ', fix: 'нужно ≥ 16 МБ свободно' },
    ],
    ...over,
  });

  it('пройденный preflight → пропускать нечего', () => {
    expect(canOverride({ passed: true, overridable: false, checks: [] })).toBe(false);
  });

  it('только soft-провалы → кнопка риска разрешена', () => {
    expect(canOverride(report())).toBe(true);
  });

  it('решение движка не переигрываем: overridable=false → кнопки нет', () => {
    const r = report({ overridable: false, hard_failed: 1 });
    expect(canOverride(r)).toBe(false);
  });

  it('нет отчёта (проверка не ответила) → кнопки нет', () => {
    expect(canOverride(null)).toBe(false);
    expect(canOverride(undefined)).toBe(false);
  });

  it('softRisks объясняет каждый soft-провал: чем грозит и что сделать вместо риска', () => {
    const risks = softRisks(report());
    expect(risks).toHaveLength(1);
    expect(risks[0].id).toBe('flash');
    expect(risks[0].title).toBe(SOFT_RISK.flash.title);
    expect(risks[0].fixes.length).toBeGreaterThan(0);
  });

  it('пройденные и hard-проверки в объяснения не попадают', () => {
    const r = report({
      checks: [
        { id: 'arch', ok: false, severity: 'hard', detail: 'arch = ppc' },
        { id: 'ram', ok: true, severity: 'soft', detail: 'RAM ≈ 512 МБ' },
      ],
    });
    expect(softRisks(r)).toEqual([]);
  });

  it('незнакомый soft-id (движок ушёл вперёд UI) не теряется — берём текст движка', () => {
    const r = report({
      checks: [{ id: 'cpu', ok: false, severity: 'soft', detail: 'CPU 1 ядро', fix: 'нужно ≥ 2' }],
    });
    const risks = softRisks(r);
    expect(risks[0]).toMatchObject({ id: 'cpu', title: 'CPU 1 ядро', risk: 'нужно ≥ 2', fixes: [] });
  });

  it('подписи для плашки панели есть на каждый известный soft-провал', () => {
    for (const id of Object.keys(SOFT_RISK)) expect(FORCED_LABELS[id]).toBeTruthy();
  });
});

describe('explainFail — адресная диагностика провала установки', () => {
  it('health: главный кейс — сервер молчит, конфиг/подписка, а не Wi-Fi', () => {
    const ex = explainFail('health');
    expect(ex.error).toMatch(/VPN-сервер не ответил/);
    expect(ex.advice.items.join(' ')).toMatch(/подписка/);
    expect(ex.advice.action).toBe('Загрузить другой конфиг');
  });

  it('health:tunnel:fetch — тот же текст, что health (это её конкретизация)', () => {
    expect(explainFail('health:tunnel:fetch')).toEqual(explainFail('health'));
  });

  it('health:dns — не про сервер: явно снимает подозрение с VPN-конфига', () => {
    const ex = explainFail('health:dns');
    expect(ex.error).toMatch(/DNS/);
    expect(ex.advice.items.join(' ')).toMatch(/конфиг тут ни при чём/);
    expect(ex.advice.items.join(' ')).not.toMatch(/подписка/);
  });

  it('step:vpn: адресно про файл конфига', () => {
    const ex = explainFail('step:vpn');
    expect(ex.error).toMatch(/VPN-конфиг не принят/);
    expect(ex.advice.items.join(' ')).toMatch(/\[Interface\]/);
  });

  it('step:<известный> подставляет человеческую подпись шага', () => {
    const ex = explainFail('step:firewall');
    expect(ex.error).toContain(STEP_LABELS.firewall);
  });

  it('step:<неизвестный> показывает сырое имя шага (не падает)', () => {
    const ex = explainFail('step:new-step');
    expect(ex.error).toContain('new-step');
  });

  it('preflight — своя ветка', () => {
    expect(explainFail('preflight').error).toMatch(/проверку/);
  });

  it('без кода причины: error=null (текст вызывающего сохраняется), генерик-советы', () => {
    const ex = explainFail(null);
    expect(ex.error).toBeNull();
    expect(ex.advice.title).toBe('Что делать');
  });
});

describe('endpoint / tunnelSummary — сводка без секретов', () => {
  const AWG = '[Interface]\nPrivateKey = SECRET\n[Peer]\nEndpoint = vpn.example.com:51820\n';

  it('endpoint достаёт Endpoint из [Peer], не выдавая ключей', () => {
    expect(endpoint(AWG)).toBe('vpn.example.com:51820');
    expect(endpoint('нет такой строки')).toBe('—');
    expect(endpoint(null)).toBe('—');
  });

  it('awg-сводка: протокол + endpoint', () => {
    expect(tunnelSummary({ protocol: 'awg', awg_conf: AWG })).toBe(
      'AmneziaWG → vpn.example.com:51820'
    );
  });
});

describe('dnsLabel / hs — метки панели', () => {
  const providers = [{ id: 'adguard', name: 'AdGuard', description: 'блокирует рекламу' }];

  it('dnsLabel: найденный провайдер → имя и описание; чужой id → как есть; пусто → дефолт', () => {
    expect(dnsLabel('adguard', providers)).toBe('AdGuard — блокирует рекламу');
    expect(dnsLabel('other', providers)).toBe('other');
    expect(dnsLabel(null, providers)).toBe('по умолчанию');
  });

  it('hs: null → нет ответа; свежий — в секундах; старый — в минутах', () => {
    expect(hs(null)).toBe('нет ответа от сервера');
    expect(hs(-5)).toBe('—');
    expect(hs(45)).toBe('отвечал 45 с назад');
    expect(hs(150)).toBe('отвечал 2 мин назад');
  });
});

// Full-тир как ЗАПАСНОЙ путь: панель обязана верно судить о туннеле любого протокола и вести к
// Reality именно тогда, когда AmneziaWG не поднимается.
// Full-тир как ЗАПАСНОЙ путь: панель обязана верно судить о туннеле любого протокола и вести к
// подходящей замене именно тогда, когда активный туннель не поднимается.
describe('heroKind / tunnelFallback / switchTargets / tunnelRowText — состояние туннеля в панели', () => {
  const st = (over = {}) => ({ installed: true, protocol: 'awg', tunnel_health: 'up', ...over });

  it('до установки баннера нет', () => {
    expect(heroKind({ installed: false })).toBe('none');
    expect(heroKind(null)).toBe('none');
  });

  it('здоровье берётся из движка, а не из локальных догадок', () => {
    expect(heroKind(st())).toBe('up');
    expect(heroKind(st({ tunnel_health: 'down' }))).toBe('down');
  });

  // Регресс: рабочий Reality показывался как «VPN не работает», потому что панель искала
  // AWG-рукопожатие, которого у VLESS нет. Legacy-роутеры живы — признак обязан работать и сейчас.
  it('legacy Full-тир: рабочий туннель зелёный без AWG-рукопожатия', () => {
    for (const [proto, label] of [['reality', 'VLESS+Reality'], ['hysteria2', 'Hysteria2']]) {
      const s = st({ protocol: proto, awg_handshake_age: null });
      expect(heroKind(s)).toBe('up');
      expect(tunnelRowText(s)).toBe(`поднят (${label})`);
      const dead = st({ protocol: proto, tunnel_health: 'down', awg_handshake_age: null });
      expect(heroKind(dead)).toBe('down');
      expect(tunnelRowText(dead)).toBe('не поднят');
    }
  });

  it('AWG: строка сводки остаётся возрастом рукопожатия (сервер отвечал)', () => {
    expect(tunnelRowText(st({ awg_handshake_age: 45 }))).toBe('отвечал 45 с назад');
    expect(tunnelRowText(st({ tunnel_health: 'down', awg_handshake_age: null }))).toBe('нет ответа от сервера');
  });

  it('с AWG уходить некуда: фолбэка и смены туннеля нет', () => {
    expect(tunnelFallback(st({ tunnel_health: 'down' }))).toBe(null);
    expect(switchTargets(st())).toEqual([]);
    expect(tunnelFallback({ installed: false })).toBe(null);
  });

  it('с legacy reality/hysteria2 — единственный путь на AmneziaWG', () => {
    for (const protocol of ['reality', 'hysteria2']) {
      expect(tunnelFallback(st({ protocol }))).toEqual({ action: 'switch', targets: ['awg'] });
      expect(switchTargets(st({ protocol })).map((p) => p.id)).toEqual(['awg']);
    }
  });
});

// Чеклист установки: план шагов зависит от наличия Wi-Fi — и обязан совпадать по порядку с
// движком, иначе «пройденные» шаги будут врать.
describe('installPlan — план шагов для чеклиста Installing', () => {
  it('без Wi-Fi: шага wifi нет', () => {
    expect(installPlan({ protocol: 'awg' }).map((s) => s.id)).toEqual(
      ['preflight', 'snapshot', 'vpn', 'dns', 'doh', 'firewall', 'health-check']);
  });

  it('с Wi-Fi: wifi между doh и firewall', () => {
    expect(installPlan({ ssid: 'Home' }).map((s) => s.id)).toEqual(
      ['preflight', 'snapshot', 'vpn', 'dns', 'doh', 'wifi', 'firewall', 'health-check']);
  });

  it('у каждого шага плана есть человеческая подпись из STEP_LABELS', () => {
    for (const s of installPlan({ ssid: 'x' })) expect(s.label).toBeTruthy();
  });
});

// Подсветка виновного поля: каждая ошибка validateSetup называет field — Setup по нему
// подсвечивает и прокручивает. Ошибка без field молча оставит человека искать поле самому.
describe('validateSetup — field называет виновное поле', () => {
  it.each([
    ['conf', { confs: { awg: '' } }],
    ['rootPass', { rootPass: 'short' }],
    ['rootPass2', { rootPass2: 'другой-пароль-9' }],
    ['ssid', { showWifi: true, wifiRequired: true, ssid: ' ', wifiKey: 'wifi-pass-1' }],
    ['wifiKey', { showWifi: true, ssid: 'Home', wifiKey: 'short' }],
    ['token', { token: '  ' }],
  ])('%s', (field, patch) => {
    const r = validateSetup(fields(patch));
    expect(r.error).toBeTruthy();
    expect(r.field).toBe(field);
  });
});

describe('серверы (профили AWG)', () => {
  it('moveProfile: соседи меняются местами, край — без изменений', () => {
    expect(moveProfile(['p1', 'p2', 'p3'], 'p2', -1)).toEqual(['p2', 'p1', 'p3']);
    expect(moveProfile(['p1', 'p2', 'p3'], 'p2', 1)).toEqual(['p1', 'p3', 'p2']);
    expect(moveProfile(['p1', 'p2'], 'p1', -1)).toEqual(['p1', 'p2']);
    expect(moveProfile(['p1', 'p2'], 'p9', 1)).toEqual(['p1', 'p2']);
  });

  it('lastSwitchText: автосмену называет прямо, ручную — коротко', () => {
    const now = 10000;
    expect(lastSwitchText(null, now)).toBe('');
    expect(lastSwitchText({ from: 'Германия', to: 'Нидерланды', at: now - 300, auto: true }, now))
      .toBe('Переключился сам 5 мин назад: сервер «Германия» не отвечал, подключён «Нидерланды».');
    expect(lastSwitchText({ from: 'A', to: 'B', at: now - 7200, auto: false }, now)).toBe('Подключён «B» 2 ч назад.');
    expect(lastSwitchText({ from: null, to: 'B', at: now, auto: true }, now)).toContain('«прежний»');
  });
});
