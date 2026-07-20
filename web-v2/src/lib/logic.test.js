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
  parseDomains, validateSetup, explainFail, STEP_LABELS,
  endpoint, tunnelSummary, dnsLabel, hs,
} from './logic.js';

// Валидная база формы: каждый тест ломает ровно одно поле.
function fields(over = {}) {
  return {
    protocol: 'awg',
    fullAvailable: false,
    awgConf: '[Interface]\nPrivateKey = x\n',
    realityConf: '',
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

describe('validateSetup — конфиг туннеля', () => {
  it('awg: пустой конфиг → просьба вставить/загрузить', () => {
    const r = validateSetup(fields({ awgConf: '   ' }));
    expect(r.error).toMatch(/AWG-конфиг/);
  });

  it('reality при fullAvailable: пустая ссылка → просьба про vless://', () => {
    const r = validateSetup(fields({ protocol: 'reality', fullAvailable: true, realityConf: ' ' }));
    expect(r.error).toMatch(/vless:\/\//);
  });

  it('reality БЕЗ fullAvailable форсится в awg (железо не тянет)', () => {
    const r = validateSetup(fields({ protocol: 'reality', fullAvailable: false, realityConf: 'vless://x' }));
    expect(r.error).toBeUndefined();
    expect(r.args.protocol).toBe('awg');
    expect(r.args.awg_conf).toBeDefined();
    expect(r.args.reality_conf).toBeUndefined();
  });

  it('reality при fullAvailable: в args уходит reality_conf, awg_conf не подмешивается', () => {
    const r = validateSetup(fields({ protocol: 'reality', fullAvailable: true, realityConf: 'vless://x' }));
    expect(r.args.protocol).toBe('reality');
    expect(r.args.reality_conf).toBe('vless://x');
    expect(r.args.awg_conf).toBeUndefined();
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
      awg_conf: '[Interface]\nPrivateKey = x\n',
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
});

describe('explainFail — адресная диагностика провала установки', () => {
  it('health: главный кейс — сервер молчит, конфиг/подписка, а не Wi-Fi', () => {
    const ex = explainFail('health');
    expect(ex.error).toMatch(/VPN-сервер не ответил/);
    expect(ex.advice.items.join(' ')).toMatch(/подписка/);
    expect(ex.advice.action).toBe('Загрузить другой конфиг');
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

  it('singbox-download и preflight — свои ветки', () => {
    expect(explainFail('singbox-download').error).toMatch(/sing-box/);
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

  it('reality-сводка: host:port из vless://, без uuid и параметров', () => {
    const s = tunnelSummary({
      protocol: 'reality',
      reality_conf: 'vless://uuid-123@srv.example.net:443?security=reality&pbk=KEY#name',
    });
    expect(s).toBe('VLESS+Reality → srv.example.net:443');
    expect(s).not.toContain('uuid-123');
    expect(s).not.toContain('pbk');
  });

  it('reality без разбираемого хоста → просто имя протокола', () => {
    expect(tunnelSummary({ protocol: 'reality', reality_conf: '{"json": true}' })).toBe('VLESS+Reality');
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
