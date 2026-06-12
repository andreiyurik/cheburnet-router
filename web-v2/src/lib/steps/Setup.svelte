<script>
  // onSubmit(args) — args для метода install: { awg_conf, root_password, [ssid, wifi_key], domains, token }.
  // onBack — вернуться на preflight. wirelessPresent — есть ли радио (из status): false → скрыть
  // Wi-Fi; true → обязателен; null (статус не ответил) → показать как необязательный.
  // initial — ранее собранные args («Назад» с экрана подтверждения не теряет введённое).
  // dnsProviders — каталог фильтрующих DNS (из status); dnsProviderDefault — дефолтный id.
  let { onSubmit, onBack, wirelessPresent = null, dnsProviders = [], dnsProviderDefault = '', initial = null } = $props();

  const MIN_PASS = 8; // минимум на ubus-границе (install.root_password.minlen)
  const SSID_MAX = 32; // IEEE 802.11
  const WIFI_KEY_MIN = 8, WIFI_KEY_MAX = 63; // WPA-PSK

  // Показываем Wi-Fi везде, кроме точно-нет-радио. Обязателен только при точно-есть-радио.
  const showWifi = $derived(wirelessPresent !== false);
  const wifiRequired = $derived(wirelessPresent === true);

  // Посев из initial намеренно одноразовый: «Назад» с подтверждения пересоздаёт компонент,
  // и поля должны вернуть ранее введённое, а не следить за пропом.
  // svelte-ignore state_referenced_locally
  let awgConf = $state(initial?.awg_conf ?? '');
  // svelte-ignore state_referenced_locally
  let rootPass = $state(initial?.root_password ?? '');
  // svelte-ignore state_referenced_locally
  let rootPass2 = $state(initial?.root_password ?? '');
  // svelte-ignore state_referenced_locally
  let ssid = $state(initial?.ssid ?? '');
  // svelte-ignore state_referenced_locally
  let wifiKey = $state(initial?.wifi_key ?? '');
  // svelte-ignore state_referenced_locally
  let domainsText = $state(initial?.domains?.join('\n') ?? '');
  // svelte-ignore state_referenced_locally
  let token = $state(initial?.token ?? '');
  // DNS-фильтрация: выбранный провайдер (initial → ранее выбранный → дефолт каталога).
  // svelte-ignore state_referenced_locally
  let dnsProvider = $state(initial?.dns_provider ?? dnsProviderDefault ?? '');
  let error = $state('');

  // Загрузка AWG-конфига файлом (вставить нормису тяжело — даём три пути: файл/вставка/—).
  async function onFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    awgConf = await f.text();
  }

  // Direct-домены: по строке или через запятую → массив. Пустые/пробелы отбрасываем
  // (движок всё равно валидирует и отбрасывает мусор — fail-safe, см. routing.build_plan).
  function parseDomains(text) {
    return text
      .split(/[\s,]+/)
      .map((d) => d.trim())
      .filter((d) => d.length > 0);
  }

  function submit() {
    error = '';
    if (awgConf.trim().length === 0) {
      error = 'Вставьте или загрузите AWG-конфиг.';
      return;
    }
    // Пароль НЕ обрезаем (в нём могут быть значимые пробелы) — сравниваем как есть.
    if (rootPass.length < MIN_PASS) {
      error = `Пароль роутера — минимум ${MIN_PASS} символов.`;
      return;
    }
    if (rootPass !== rootPass2) {
      error = 'Пароли роутера не совпадают.';
      return;
    }

    // Wi-Fi: собираем только если секция показана и (обязательна ИЛИ хоть одно поле заполнено).
    // Пароль Wi-Fi НЕ обрезаем (значимые пробелы); SSID — да (крайние пробелы — частая опечатка).
    let wifiArgs = {};
    if (showWifi) {
      const ssidTrim = ssid.trim();
      const wifiFilled = ssidTrim.length > 0 || wifiKey.length > 0;
      if (wifiRequired || wifiFilled) {
        if (ssidTrim.length < 1 || ssidTrim.length > SSID_MAX) {
          error = `Имя Wi-Fi (SSID) — от 1 до ${SSID_MAX} символов.`;
          return;
        }
        if (wifiKey.length < WIFI_KEY_MIN || wifiKey.length > WIFI_KEY_MAX) {
          error = `Пароль Wi-Fi — от ${WIFI_KEY_MIN} до ${WIFI_KEY_MAX} символов.`;
          return;
        }
        wifiArgs = { ssid: ssidTrim, wifi_key: wifiKey };
      }
    }

    if (token.trim().length === 0) {
      error = 'Введите install-токен (его напечатал bootstrap по SSH).';
      return;
    }
    onSubmit({
      awg_conf: awgConf,
      root_password: rootPass,
      ...wifiArgs,
      ...(dnsProvider ? { dns_provider: dnsProvider } : {}),
      domains: parseDomains(domainsText),
      token: token.trim(),
    });
  }
</script>

<section>
  <h2>Настройка</h2>

  <label>
    <span>AWG-конфиг провайдера</span>
    <textarea
      bind:value={awgConf}
      rows="8"
      placeholder="[Interface]&#10;PrivateKey = …&#10;Address = …&#10;[Peer]&#10;PublicKey = …&#10;Endpoint = host:port"
    ></textarea>
  </label>
  <label class="file">
    <span>…или загрузить файлом</span>
    <input type="file" accept=".conf,text/plain" onchange={onFile} />
  </label>

  <label>
    <span>Домены прямого доступа <em>(необязательно)</em></span>
    <textarea
      bind:value={domainsText}
      rows="3"
      placeholder="example.com&#10;example.org"
    ></textarea>
    <small class="muted">Эти домены идут напрямую; весь остальной трафик — через туннель.</small>
  </label>

  <h3>Пароль роутера</h3>
  <label>
    <span>Пароль администратора (root)</span>
    <input type="password" bind:value={rootPass} autocomplete="new-password" placeholder="минимум {MIN_PASS} символов" />
    <small class="muted">Им вы входите в роутер по SSH и в панель управления. Запомните его.</small>
  </label>
  <label>
    <span>Повторите пароль</span>
    <input type="password" bind:value={rootPass2} autocomplete="new-password" placeholder="ещё раз тот же пароль" />
  </label>

  {#if showWifi}
    <h3>Wi-Fi {#if !wifiRequired}<em>(необязательно)</em>{/if}</h3>
    <label>
      <span>Имя сети (SSID)</span>
      <input type="text" bind:value={ssid} maxlength={SSID_MAX} placeholder="например, MyHome" />
    </label>
    <label>
      <span>Пароль Wi-Fi</span>
      <input type="password" bind:value={wifiKey} autocomplete="new-password" placeholder="минимум {WIFI_KEY_MIN} символов" />
      <small class="muted">WPA2/WPA3 (если доступно). Минимум {WIFI_KEY_MIN} символов.</small>
    </label>
    {#if wirelessPresent === null}
      <small class="muted">Не удалось узнать, есть ли у роутера Wi-Fi — заполните, если он есть; иначе оставьте пустым.</small>
    {/if}
  {/if}

  {#if dnsProviders.length > 0}
    <h3>Фильтрация (DNS)</h3>
    <label>
      <span>Блокировка рекламы / взрослого контента</span>
      <select bind:value={dnsProvider}>
        {#each dnsProviders as p}
          <option value={p.id}>{p.name} — {p.description}</option>
        {/each}
      </select>
      <small class="muted">«Семейный» провайдер дополнительно блокирует сайты 18+ и форсит безопасный поиск. Менять можно позже.</small>
    </label>
  {/if}

  <label>
    <span>Install-токен</span>
    <input type="text" bind:value={token} placeholder="из вывода bootstrap по SSH" />
  </label>

  {#if error}<p class="warn">{error}</p>{/if}

  <div class="row">
    <button onclick={onBack}>Назад</button>
    <button class="primary" onclick={submit}>Установить</button>
  </div>
</section>
