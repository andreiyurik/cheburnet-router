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

// validateSetup(f) → { error } | { args } — проверка полей Setup и сборка аргументов install.
// f: { protocol, fullAvailable, awgConf, realityConf, rootPass, rootPass2,
//      showWifi, wifiRequired, ssid, wifiKey, dnsProvider, domainsText, token }.
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

// Возраст последнего AWG-handshake → человеческая строка для панели.
export function hs(age) {
  if (age == null) return 'нет ответа от сервера';
  if (age < 0) return '—';
  if (age < 120) return `отвечал ${age} с назад`;
  return `отвечал ${Math.floor(age / 60)} мин назад`;
}
