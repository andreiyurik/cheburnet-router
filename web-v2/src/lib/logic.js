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

// Чего не хватает железу для Full-тира (status.full_missing) — человеческими словами.
// Молчаливо спрятанная кнопка выглядит как «функцию убрали»; названная причина — как выбор.
export const FULL_MISSING_LABELS = {
  arch: 'нужен 64-битный процессор с AES (у этого роутера другой)',
  ram: 'нужно от 256 МБ оперативной памяти',
  flash: 'не хватает свободного места: компоненту нужно ~42 МБ',
};

export function fullMissingText(missing) {
  return (missing ?? []).map((m) => FULL_MISSING_LABELS[m] ?? m).join('; ');
}

// explainFullTierFail(reason) → текст для панели, когда догрузка sing-box не удалась.
// reason пишет install-singbox.sh: "no-space" — не влез на флеш, "download" (или ничего) — сеть.
// Смысл разделения тот же, что у explainFail: не отправлять человека чинить не то.
export function explainFullTierFail(reason) {
  if (reason === 'no-space')
    return 'Не хватило места на роутере: компоненту VLESS+Reality нужно ~15 МБ свободного флеша. ' +
      'Освободите место (по SSH: apk del ненужные пакеты) или подключите USB-флешку (extroot). ' +
      'AmneziaWG не затронут — он продолжает работать.';
  return 'Не удалось скачать sing-box — проверьте, что роутер в интернете, и попробуйте ещё раз. ' +
    'AmneziaWG не затронут.';
}

// fullReasons(report) → почему Full-тир (VLESS+Reality) недоступен, человеческими фразами из
// движка (tiers.full_checks: «RAM ≈ 120 МБ → Full-тиру нужно ≥ 240 МБ»). Пусто, если тянет.
// Reality — запасной путь на случай, когда AmneziaWG режут; человек должен понимать, почему
// этот путь ему закрыт, а не видеть безликое «недоступно».
export function fullReasons(report) {
  if (report?.tiers?.full === true) return [];
  return (report?.tiers?.full_checks ?? [])
    .filter((c) => !c.ok)
    .map((c) => `${c.detail}${c.fix ? ` (${c.fix})` : ''}`);
}

// canOverride(report) → показывать ли кнопку «установить на свой страх и риск».
// Источник правды — движок (overridable = провалы есть и все они soft); UI его не переигрывает.
export function canOverride(report) {
  return report?.passed !== true && report?.overridable === true;
}

// validateSetup(f) → { error } | { args } — проверка полей Setup и сборка аргументов install.
// f: { protocol, fullAvailable, awgConf, realityConf, rootPass, rootPass2,
//      showWifi, wifiRequired, ssid, wifiKey, dnsProvider, domainsText, token, acceptRisk }.
export function validateSetup(f) {
  // Конфиг активного туннеля. reality доступен только при fullAvailable; на всякий случай
  // (если железо не тянет) форсим awg даже при protocol==reality из initial.
  const useReality = f.protocol === 'reality' && f.fullAvailable;
  if (useReality) {
    if (f.realityConf.trim().length === 0)
      return { error: 'Вставьте ссылку vless://… или JSON-конфиг sing-box.' };
  } else if (f.awgConf.trim().length === 0) {
    return { error: 'Вставьте или загрузите AWG-конфиг.' };
  }
  // Пароль НЕ обрезаем (в нём могут быть значимые пробелы) — сравниваем как есть.
  if (f.rootPass.length < MIN_PASS)
    return { error: `Пароль роутера — минимум ${MIN_PASS} символов.` };
  if (f.rootPass !== f.rootPass2)
    return { error: 'Пароли роутера не совпадают.' };

  // Wi-Fi: собираем только если секция показана и (обязательна ИЛИ хоть одно поле заполнено).
  // Пароль Wi-Fi НЕ обрезаем (значимые пробелы); SSID — да (крайние пробелы — частая опечатка).
  let wifiArgs = {};
  if (f.showWifi) {
    const ssidTrim = f.ssid.trim();
    const wifiFilled = ssidTrim.length > 0 || f.wifiKey.length > 0;
    if (f.wifiRequired || wifiFilled) {
      if (ssidTrim.length < 1 || ssidTrim.length > SSID_MAX)
        return { error: `Имя Wi-Fi (SSID) — от 1 до ${SSID_MAX} символов.` };
      if (f.wifiKey.length < WIFI_KEY_MIN || f.wifiKey.length > WIFI_KEY_MAX)
        return { error: `Пароль Wi-Fi — от ${WIFI_KEY_MIN} до ${WIFI_KEY_MAX} символов.` };
      wifiArgs = { ssid: ssidTrim, wifi_key: f.wifiKey };
    }
  }

  if (f.token.trim().length === 0)
    return { error: 'Введите код установки — он напечатан в терминале после команды установки.' };

  return {
    args: {
      protocol: useReality ? 'reality' : 'awg',
      ...(useReality ? { reality_conf: f.realityConf } : { awg_conf: f.awgConf }),
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
  'singbox-download': 'Загрузка компонента VLESS+Reality (~15 МБ)',
  snapshot: 'Сохранение точки отката',
  vpn: 'Настройка VPN-туннеля',
  singbox: 'Настройка VPN-туннеля',
  dns: 'Настройка DNS и split-routing',
  doh: 'Шифрованный DNS',
  wifi: 'Настройка Wi-Fi',
  firewall: 'Firewall и kill-switch',
  'health-check': 'Проверка связи (поднятие туннеля, до ~30 сек)',
};

// explainFail(reason) → { error, advice } — адресная диагностика по машинному коду исхода
// (install_progress.reason). error=null у генерик-ветки: компонент сохраняет свой текст
// («Установка не удалась» / «Установщик аварийно завершился»).
// Главный кейс: health — роутер настроен ПРАВИЛЬНО, но VPN-сервер не ответил. Без этого
// человек с протухшей подпиской дёргает Wi-Fi и пароли вместо конфига.
export function explainFail(reason) {
  if (reason === 'health') {
    return {
      error: 'VPN-сервер не ответил — туннель не поднялся.',
      advice: {
        title: 'Роутер настроен правильно, но сервер из вашего VPN-конфига молчит. Изменения откатаны. Чаще всего это значит:',
        items: [
          'подписка у VPN-провайдера закончилась или сервер отключён — проверьте личный кабинет;',
          'конфиг устарел — скачайте свежий файл .conf и загрузите его заново;',
          'провайдер интернета мешает VPN-протоколу — попробуйте конфиг с другим сервером.',
        ],
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
  if (reason === 'singbox-download') {
    return {
      error: 'Не удалось загрузить компонент sing-box.',
      advice: {
        title: 'Изменений на роутере нет. Для VLESS+Reality нужно скачать компонент sing-box (~15 МБ) с серверов OpenWrt:',
        items: [
          'проверьте, что роутер подключён к интернету (кабель WAN на месте);',
          'иногда загрузка рвётся из-за сети провайдера — просто попробуйте ещё раз;',
          'либо вернитесь и выберите AmneziaWG — он не требует догрузки.',
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

// Краткая сводка туннеля без секретов: протокол + хост сервера.
export function tunnelSummary(args) {
  if (args.protocol === 'reality') {
    const m = (args.reality_conf ?? '').match(/@([^?#/]+)/); // host:port после uuid@
    return m ? `VLESS+Reality → ${m[1]}` : 'VLESS+Reality';
  }
  return `AmneziaWG → ${endpoint(args.awg_conf)}`;
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

// heroKind(s) → какой главный баннер показать. Разное железо сигнала → разные формулировки:
// у AWG есть доказательство «сервер отвечал N сек назад», у Reality — только «туннель поднят»,
// поэтому обещать «всё работает» там нельзя (см. tunnel_health в engine/install/install.uc).
export function heroKind(s) {
  if (!s?.installed) return 'none';
  const reality = s.protocol === 'reality';
  if (s.tunnel_health === 'up') return reality ? 'reality-up' : 'awg-up';
  return reality ? 'reality-down' : 'awg-down';
}

// realityFallback(s) → что предложить, когда AmneziaWG не поднимается: 'install' (железо тянет,
// sing-box ещё не догружен) | 'switch' (уже стоит — переключиться в один шаг) | null (нечего
// предлагать: слабое железо или Reality уже активен). Это главный сценарий Full-тира — запасной
// путь, когда сеть режет UDP-туннель.
export function realityFallback(s) {
  if (s?.protocol === 'reality') return null;
  if (s?.full_installed) return 'switch';
  if (s?.full_capable) return 'install';
  return null;
}

// tunnelRowText(s) → значение строки «Туннель» в сводке. У AWG — возраст рукопожатия (сервер
// отвечал), у Reality — факт поднятого туннеля, без обещаний про сервер.
export function tunnelRowText(s) {
  if (s?.protocol === 'reality')
    return s?.tunnel_health === 'up' ? 'поднят (VLESS+Reality)' : 'не поднят';
  return hs(s?.awg_handshake_age);
}

// Возраст последнего AWG-handshake → человеческая строка для панели.
export function hs(age) {
  if (age == null) return 'нет ответа от сервера';
  if (age < 0) return '—';
  if (age < 120) return `отвечал ${age} с назад`;
  return `отвечал ${Math.floor(age / 60)} мин назад`;
}
