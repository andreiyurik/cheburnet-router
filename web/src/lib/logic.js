// logic.js — чистая логика мастера и панели, вынесенная из Svelte-компонентов под vitest.
//
// Здесь нет DOM/сети/состояния — только функции «вход → значение»: валидация формы Setup,
// разбор конфигов для сводки Confirm, карта причин провала для Installing, форматтеры Status.
// Компоненты остаются тонкими (состояние + разметка), а границу с пользователем проверяют юниты.

// Лимиты формы Setup. MIN_PASS зеркалит ubus-границу (install.root_password.minlen);
// SSID/WPA-PSK — из стандартов (IEEE 802.11 / WPA).
export const MIN_PASS = 8;
export const SSID_MAX = 32;
export const WIFI_KEY_MIN = 8;
export const WIFI_KEY_MAX = 63;

// Куда писать, если не работает — одно место на весь UI (копии на трёх экранах разъезжались).
// Страница проекта рядом с личным контактом: ссылка, вшитая в прошивку, живёт годами, канал связи
// может смениться — страница долговечный ориентир, Telegram — быстрый путь сегодня.
export const SUPPORT = {
  telegram: '@industrialprofi',
  telegramUrl: 'https://t.me/industrialprofi',
  page: 'https://github.com/andreiyurik/cheburnet-router',
  donateUrl: 'https://pay.cloudtips.ru/p/61fe8ef3',
};

// --- Каталог туннельных протоколов (три оси покрытия, ADR 0004) ---
// Зеркалит PROTOCOLS движка (engine/install/install.uc; синхронность стережёт engine-sync.test.js)
// плюс то, чего в движке быть не должно: как объяснить протокол ЧЕЛОВЕКУ — от поломки, не от
// названия. why — одна строка; whyMore — под «Подробнее»; sniff/sniffError —
// дешёвая проверка формата ДО отправки (отказ движка стоит трёх минут установки и отката).
export const PROTOCOLS = {
  awg: {
    id: 'awg',
    name: 'AmneziaWG',
    confKey: 'awg_conf',
    // Симптом, при котором этот протокол — верный выбор.
    symptom: 'Роутер слабый или хочется максимально быстро',
    why: 'Считается прямо в ядре роутера: самая высокая скорость, минимум нагрузки.',
    whyMore: 'Ядро маршрутизирует пакеты без промежуточной программы, поэтому процессор почти не греется, а скорость упирается в канал, а не в роутер.',
    // Что просим вставить.
    confLabel: 'VPN-конфиг (AmneziaWG, файл .conf)',
    confHint: 'Его выдаёт ваш VPN-провайдер (конфиг «для роутеров») или ваш собственный сервер.',
    placeholder: '[Interface]\nPrivateKey = …\nAddress = …\n[Peer]\nPublicKey = …\nEndpoint = host:port',
    sniff: /\[Interface\]/i,
    sniffError: 'Похоже, это не конфиг AmneziaWG: в нём должна быть строка [Interface]. Вставьте файл .conf целиком или загрузите его кнопкой ниже.',
    // Загрузка файлом уместна только для .conf (ссылку удобнее вставить).
    file: true,
    full: false,
    switchMethod: 'switch_to_awg',
    replaceMethod: 'replace_awg_conf',
  },
  // Заморожены (ADR 0009/0010): в мастере и смене туннеля их нет, но панель роутера, который на них
  // остался, должна назвать протокол правильно и предложить уйти на AWG — а не притвориться им.
  reality: { id: 'reality', name: 'VLESS+Reality', legacy: true, full: true },
  hysteria2: { id: 'hysteria2', name: 'Hysteria2', legacy: true, full: true },
};

// checkConf(id, text) → '' | текст ошибки. Одна проверка на мастер и на панель: замена сервера и
// смена туннеля упираются в тот же формат, и там цена ошибки та же (фоновая операция + откат).
export function checkConf(id, text) {
  const info = protocolInfo(id);
  const s = (text ?? '').trim();
  if (s.length === 0)
    return `Вставьте ${info.file ? 'или загрузите ' : ''}${info.confLabel.toLowerCase()}.`;
  return info.sniff.test(s) ? '' : info.sniffError;
}

// Порядок показа в мастере и панели (legacy-протоколов здесь нет — их не выбирают).
export const PROTOCOL_ORDER = ['awg'];

export function protocolList() {
  return PROTOCOL_ORDER.map((id) => PROTOCOLS[id]);
}

export function protocolInfo(id) {
  return PROTOCOLS[id] ?? PROTOCOLS.awg; // неизвестный → дефолт (fail-safe, как в движке)
}

// Direct-домены: по строке или через запятую → массив. Пустые/пробелы отбрасываем
// (движок всё равно валидирует и отбрасывает мусор — fail-safe, см. routing.build_plan).
export function parseDomains(text) {
  return text
    .split(/[\s,]+/)
    .map((d) => d.trim())
    .filter((d) => d.length > 0);
}

// --- Пропуск проверок железа («на свой страх и риск») ---
//
// Движок делит проверки preflight на hard (пропустить нельзя — пакетов под эту платформу просто
// нет) и soft (железо впритык: флеш/RAM). Мастер предлагает установку с пропуском ТОЛЬКО когда
// все провалы soft (report.overridable), и обязан сначала объяснить: что грозит и что можно
// сделать ВМЕСТО риска. Кнопка — последний вариант, а не первый (см. engine/preflight/preflight.uc).
export const SOFT_RISK = {
  flash: {
    title: 'Мало свободного места в памяти роутера (флеш)',
    risk: 'Пакеты могут не поместиться. Тогда установка прервётся на середине и сама вернёт роутер в исходное состояние — но времени это займёт.',
    fixes: [
      'освободить место: по SSH удалить ненужные пакеты командой apk del — часто это лишние темы и приложения LuCI;',
      'подключить USB-флешку и вынести систему на неё (extroot) — после этого места хватает с запасом.',
    ],
  },
  ram: {
    title: 'Мало оперативной памяти (RAM)',
    risk: 'Установка, скорее всего, пройдёт, но под нагрузкой роутер может тормозить или перезагружаться из-за нехватки памяти.',
    fixes: [
      'держать список доменов прямого доступа коротким — одна запись зоны покрывает все домены внутри неё;',
      'включить сжатый swap в оперативной памяти — пакет zram-swap, он сглаживает пики.',
    ],
  },
};

// softRisks(report) → пояснения по каждой провалившейся soft-проверке (в порядке отчёта).
// Незнакомый id (движок добавил soft-проверку раньше UI) не теряем — показываем текст движка.
export function softRisks(report) {
  return (report?.checks ?? [])
    .filter((c) => !c.ok && c.severity === 'soft')
    .map((c) => {
      const known = SOFT_RISK[c.id];
      return known
        ? { id: c.id, ...known }
        : { id: c.id, title: c.detail, risk: c.fix ?? '', fixes: [] };
    });
}

// Подписи пропущенных проверок для плашки в панели (status.forced приходит из install.json).
export const FORCED_LABELS = { flash: 'мало свободного места', ram: 'мало оперативной памяти' };

// canOverride(report) → показывать ли кнопку «установить на свой страх и риск».
// Источник правды — движок (overridable = провалы есть и все они soft); UI его не переигрывает.
export function canOverride(report) {
  return report?.passed !== true && report?.overridable === true;
}

// validateSetup(f) → { error, field } | { args } — проверка полей Setup и сборка аргументов install.
// field (conf|rootPass|rootPass2|ssid|wifiKey|token) — Setup подсвечивает и прокручивает к
// нему: на длинной форме ошибка у кнопки оказывалась за два экрана от поля. f — поля формы Setup.
export function validateSetup(f) {
  const proto = 'awg'; // единственный устанавливаемый протокол (ADR 0010)
  const info = protocolInfo(proto);
  const conf = (f.confs?.[proto] ?? '').trim();
  const confError = checkConf(proto, conf);
  if (confError) return { error: confError, field: 'conf' };

  // Пароль НЕ обрезаем (в нём могут быть значимые пробелы) — сравниваем как есть.
  if (f.rootPass.length < MIN_PASS)
    return { error: `Пароль роутера — минимум ${MIN_PASS} символов.`, field: 'rootPass' };
  if (f.rootPass !== f.rootPass2)
    return { error: 'Пароли роутера не совпадают.', field: 'rootPass2' };

  // Wi-Fi: собираем только если секция показана и (обязательна ИЛИ хоть одно поле заполнено).
  // Пароль Wi-Fi НЕ обрезаем (значимые пробелы); SSID — да (крайние пробелы — частая опечатка).
  let wifiArgs = {};
  if (f.showWifi) {
    const ssidTrim = f.ssid.trim();
    const wifiFilled = ssidTrim.length > 0 || f.wifiKey.length > 0;
    if (f.wifiRequired || wifiFilled) {
      if (ssidTrim.length < 1 || ssidTrim.length > SSID_MAX)
        return { error: `Имя Wi-Fi (SSID) — от 1 до ${SSID_MAX} символов.`, field: 'ssid' };
      if (f.wifiKey.length < WIFI_KEY_MIN || f.wifiKey.length > WIFI_KEY_MAX)
        return { error: `Пароль Wi-Fi — от ${WIFI_KEY_MIN} до ${WIFI_KEY_MAX} символов.`, field: 'wifiKey' };
      wifiArgs = { ssid: ssidTrim, wifi_key: f.wifiKey };
    }
  }

  if (f.token.trim().length === 0)
    return { error: 'Введите код установки — он напечатан в терминале после команды установки.', field: 'token' };

  return {
    args: {
      protocol: proto,
      // Конфиг кладём под ключом протокола (confKey) — тем же, что читает движок по PROTOCOLS.
      [info.confKey]: conf,
      root_password: f.rootPass,
      ...wifiArgs,
      ...(f.dnsProvider ? { dns_provider: f.dnsProvider } : {}),
      domains: parseDomains(f.domainsText),
      // Согласие на пропуск soft-проверок железа несём до самой установки: preflight в движке
      // выполняется ЕЩЁ РАЗ перед snapshot'ом и без этого флага честно откажет.
      ...(f.acceptRisk ? { accept_risk: true } : {}),
      token: f.token.trim(),
    },
  };
}

// Понятные подписи технических шагов движка (STATE_FILE) — что именно идёт сейчас.
export const STEP_LABELS = {
  starting: 'Запуск…',
  preflight: 'Проверка роутера',
  snapshot: 'Сохранение точки отката',
  vpn: 'Настройка VPN-туннеля',
  singbox: 'Настройка VPN-туннеля',
  dns: 'Настройка DNS и split-routing',
  doh: 'Шифрованный DNS',
  wifi: 'Настройка Wi-Fi',
  firewall: 'Firewall и kill-switch',
  'health-check': 'Проверка связи (поднятие туннеля, до ~30 сек)',
};

// installPlan(args) → [{ id, label }] — ожидаемая последовательность шагов этой установки
// для чеклиста Installing: wifi — только при SSID.
// ИНВАРИАНТ: порядок повторяет последовательность шагов движка (как в STEP_LABELS).
export function installPlan(args) {
  const ids = ['preflight', 'snapshot', 'vpn', 'dns', 'doh'];
  if (args?.ssid) ids.push('wifi');
  ids.push('firewall', 'health-check');
  return ids.map((id) => ({ id, label: STEP_LABELS[id] }));
}

// explainFail(reason, protocol?) → { error, advice } — адресная диагностика по коду исхода
// (install_progress.reason; error=null → компонент оставляет свой текст). ШРАМ: все health:*
// схлопывались в «сервер молчит, проверьте подписку», а причиной бывал баг на роутере (health:dns) —
// код и совет обязаны совпадать 1:1 с install.uc.decide_outcome.
export function explainFail(reason) {
  if (reason === 'health:dns') {
    return {
      error: 'DNS на роутере не ответил.',
      advice: {
        title: 'Роутер настроен правильно, туннель до сервера в порядке — не откликнулся резолвер DNS на самом роутере. Изменения откатаны. Обычно это значит:',
        items: [
          'разовый сбой при первом старте службы — чаще всего помогает просто попробовать ещё раз;',
          'если повторяется — попробуйте другого DNS-провайдера на шаге настройки;',
          'ваш VPN-конфиг тут ни при чём — трогать его не нужно.',
        ],
        action: 'Попробовать снова',
      },
    };
  }
  if (reason === 'health' || reason === 'health:tunnel:fetch') {
    const items = [
      'подписка у VPN-провайдера закончилась или сервер отключён — проверьте личный кабинет;',
      'конфиг устарел — скачайте свежий файл .conf и загрузите его заново;',
      'провайдер интернета мешает VPN-протоколу — попробуйте конфиг с другим сервером.',
    ];
    return {
      error: 'VPN-сервер не ответил — туннель не поднялся.',
      advice: {
        title: 'Роутер настроен правильно, но сервер из вашего VPN-конфига молчит. Изменения откатаны. Чаще всего это значит:',
        items,
        action: 'Загрузить другой конфиг',
      },
    };
  }
  if (reason === 'step:vpn') {
    return {
      error: 'VPN-конфиг не принят.',
      advice: {
        title: 'Изменения откатаны. Проверьте файл конфига:',
        items: [
          'он вставлен целиком — от строки [Interface] до конца;',
          'это конфиг AmneziaWG/WireGuard «для роутеров» (.conf), а не ссылка или QR-код.',
        ],
        action: 'Исправить конфиг',
      },
    };
  }
  if (reason && reason.startsWith('step:')) {
    const s = reason.slice(5);
    return {
      error: `Сбой на этапе «${STEP_LABELS[s] ?? s}».`,
      advice: {
        title: 'Изменения откатаны — роутер в исходном состоянии. Что можно сделать:',
        items: [
          'попробуйте ещё раз — разовые сбои случаются;',
          'если повторяется — скопируйте журнал ниже и приложите его к вопросу в сообществе проекта.',
        ],
        action: 'Попробовать снова',
      },
    };
  }
  if (reason === 'preflight') {
    return {
      error: 'Роутер не прошёл проверку.',
      advice: {
        title: 'Изменений нет. Вернитесь назад — с экрана настройки кнопка «Назад» запустит проверку заново и покажет, что именно не так.',
        items: [],
        action: 'Назад к настройке',
      },
    };
  }
  // Код не пришёл (старый пакет / crash) — прежний общий текст.
  return {
    error: null,
    advice: {
      title: 'Что делать',
      items: [
        'Изменения откатаны — роутер в исходном состоянии, можно пробовать снова.',
        'Частые причины: опечатка в AWG-конфиге (вставлен не целиком), нет интернета на WAN, недоступен сервер VPN-провайдера.',
        'Не получается — скопируйте журнал ниже и приложите его к вопросу в сообществе проекта.',
      ],
      action: 'Изменить данные и повторить',
    },
  };
}

// Первая строка [Peer]→Endpoint — единственное, что безопасно показать из AWG-конфига.
export function endpoint(conf) {
  const m = (conf ?? '').match(/^\s*Endpoint\s*=\s*(.+)$/m);
  return m ? m[1].trim() : '—';
}

// Краткая сводка туннеля без секретов: протокол + адрес сервера (ключей из .conf не показываем).
export function tunnelSummary(args) {
  return `${PROTOCOLS.awg.name} → ${endpoint(args?.awg_conf)}`;
}

// Человекочитаемая метка фильтрации по выбранному id (или дефолт-описание).
export function dnsLabel(id, providers) {
  const p = (providers ?? []).find((x) => x.id === id);
  return p ? `${p.name} — ${p.description}` : (id ?? 'по умолчанию');
}

// --- Состояние туннеля в панели (протокол-независимо) ---
//
// Здоровье приходит из движка одним полем status.tunnel_health ("up"|"down") — он знает, чем
// мерить каждый протокол (AWG — рукопожатие сервера, Reality — живой sing-box + поднятый TUN).
// Панель НЕ пересчитывает это сама: раньше она судила по AWG-рукопожатию и на рабочем Reality
// показывала «VPN не работает», ведя заменять AWG-конфиг (движок такую замену и не принял бы).

// heroKind(s) → какой главный баннер показать: 'none' | 'up' | 'down'. Протокол берётся отдельно
// (heroProtocol), потому что ФОРМУЛИРОВКА зависит от него: у AWG есть доказательство «сервер
// отвечал N сек назад», у Full-протоколов — только «туннель поднят», поэтому обещать «всё
// работает» там нельзя (см. tunnel_health в engine/install/install.uc).
export function heroKind(s) {
  if (!s?.installed) return 'none';
  return s.tunnel_health === 'up' ? 'up' : 'down';
}

// tunnelFallback(s) → куда уйти, когда активный туннель не поднимается: с legacy Full-тира
// (ADR 0010) — на AWG; с AWG уходить некуда (null) — помогают другой сервер или аварийный режим.
export function tunnelFallback(s) {
  if (!s?.installed || !protocolInfo(s.protocol).legacy) return null;
  return { action: 'switch', targets: ['awg'] };
}

// switchTargets(s) → протоколы, на которые можно переключиться: только уход с legacy на AWG.
export function switchTargets(s) {
  return protocolInfo(s?.protocol).legacy ? [PROTOCOLS.awg] : [];
}

// tunnelRowText(s) → значение строки «Туннель» в сводке. У AWG — возраст рукопожатия (сервер
// отвечал), у legacy Full-тира — факт поднятого туннеля, без обещаний про сервер.
export function tunnelRowText(s) {
  const info = protocolInfo(s?.protocol);
  if (info.full)
    return s?.tunnel_health === 'up' ? `поднят (${info.name})` : 'не поднят';
  return hs(s?.awg_handshake_age);
}

// Возраст последнего AWG-handshake → человеческая строка для панели.
export function hs(age) {
  if (age == null) return 'нет ответа от сервера';
  if (age < 0) return '—';
  if (age < 120) return `отвечал ${age} с назад`;
  return `отвечал ${Math.floor(age / 60)} мин назад`;
}

// moveProfile(ids, id, delta) → новый порядок серверов (delta −1 = выше по приоритету). Край
// списка — без изменений: кнопка «выше» у первого ничего не ломает.
export function moveProfile(ids, id, delta) {
  const i = ids.indexOf(id), j = i + delta;
  if (i < 0 || j < 0 || j >= ids.length) return ids;
  const out = [...ids];
  [out[i], out[j]] = [out[j], out[i]];
  return out;
}

// lastSwitchText(ls, now) → '' | фраза о последней смене сервера (profiles.json last_switch,
// unix-секунды). Автоматическую называем прямо: иначе человек не поймёт, почему «страна сменилась сама».
export function lastSwitchText(ls, now) {
  if (!ls || !ls.to) return '';
  const min = Math.max(0, Math.floor((now - ls.at) / 60));
  const when = min < 1 ? 'только что' : min < 60 ? `${min} мин назад`
    : min < 1440 ? `${Math.floor(min / 60)} ч назад` : `${Math.floor(min / 1440)} дн назад`;
  if (ls.auto)
    return `Переключился сам ${when}: сервер «${ls.from ?? 'прежний'}» не отвечал, подключён «${ls.to}».`;
  return `Подключён «${ls.to}» ${when}.`;
}
