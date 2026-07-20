<script>
  // onSubmit(args) — args для метода install: { awg_conf, root_password, [ssid, wifi_key], domains, token }.
  // onBack — вернуться на preflight. wirelessPresent — есть ли радио (из status): false → скрыть
  // Wi-Fi; true → обязателен; null (статус не ответил) → показать как необязательный.
  // initial — ранее собранные args («Назад» с экрана подтверждения не теряет введённое).
  // dnsProviders — каталог фильтрующих DNS (из status); dnsProviderDefault — дефолтный id.
  // fullAvailable — ТЯНЕТ ли железо Full-тир (из preflight.tiers.full): true → VLESS+Reality
  // доступен для выбора (sing-box догрузится автоматически при установке); false → строка Reality
  // показана НЕактивной с пояснением про требования (образовательно), выбрать нельзя. Дефолт — AWG.
  import { MIN_PASS, SSID_MAX, WIFI_KEY_MIN, validateSetup } from '../logic.js';

  let { onSubmit, onBack, wirelessPresent = null, dnsProviders = [], dnsProviderDefault = '', fullAvailable = false, urlToken = '', initial = null } = $props();

  // Показываем Wi-Fi везде, кроме точно-нет-радио. Обязателен только при точно-есть-радио.
  const showWifi = $derived(wirelessPresent !== false);
  const wifiRequired = $derived(wirelessPresent === true);

  // Посев из initial намеренно одноразовый: «Назад» с подтверждения пересоздаёт компонент,
  // и поля должны вернуть ранее введённое, а не следить за пропом.
  // Туннель: протокол (awg=Light по умолчанию | reality=Full) + конфиги под каждый.
  // svelte-ignore state_referenced_locally
  let protocol = $state(initial?.protocol ?? 'awg');
  // svelte-ignore state_referenced_locally
  let awgConf = $state(initial?.awg_conf ?? '');
  // svelte-ignore state_referenced_locally
  let realityConf = $state(initial?.reality_conf ?? '');
  // svelte-ignore state_referenced_locally
  let rootPass = $state(initial?.root_password ?? '');
  // svelte-ignore state_referenced_locally
  let rootPass2 = $state(initial?.root_password ?? '');
  // svelte-ignore state_referenced_locally
  let ssid = $state(initial?.ssid ?? '');
  // svelte-ignore state_referenced_locally
  let wifiKey = $state(initial?.wifi_key ?? '');
  // Direct-список предзаполнен зонной записью: dnsmasq матчит домены по суффиксу, поэтому одна
  // запись верхнего уровня (например «ru») покрывает все домены этой зоны — без больших списков.
  // Это редактируемый дефолт: содержимое списка решает пользователь.
  // svelte-ignore state_referenced_locally
  let domainsText = $state(initial?.domains?.join('\n') ?? 'ru');
  // Токен: ранее введённый → из ссылки (?token=…) → пусто (ручной ввод).
  // svelte-ignore state_referenced_locally
  let token = $state(initial?.token ?? urlToken ?? '');
  // Токен пришёл из ссылки → поле не показываем (лишний технический вопрос для человека,
  // который просто кликнул по ссылке из терминала); «изменить» раскрывает ручной ввод.
  // svelte-ignore state_referenced_locally
  let tokenEditable = $state(!(urlToken && token === urlToken));
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

  // Валидация и сборка аргументов install — чистая validateSetup (logic.js, под vitest).
  function submit() {
    error = '';
    const r = validateSetup({
      protocol, fullAvailable, awgConf, realityConf, rootPass, rootPass2,
      showWifi, wifiRequired, ssid, wifiKey, dnsProvider, domainsText, token,
    });
    if (r.error) {
      error = r.error;
      return;
    }
    onSubmit(r.args);
  }
</script>

<section>
  <h2>Настройка</h2>

  <h3>Протокол туннеля</h3>
  <label class="radio">
    <input type="radio" bind:group={protocol} value="awg" />
    <span><strong>AmneziaWG</strong> — рекомендуем. Лёгкий и быстрый, работает в ядре роутера:
      меньше нагрузка, идёт даже на слабом железе.</span>
  </label>
  <label class="radio" class:disabled={!fullAvailable}>
    <input type="radio" bind:group={protocol} value="reality" disabled={!fullAvailable} />
    <span><strong>VLESS + Reality</strong> — альтернатива для сетей с жёстким DPI: маскируется под
      обычный HTTPS. Требует более мощный роутер (64-битный CPU с AES, ≥ 256 МБ RAM, ≥ 128 МБ флеша)
      и догрузит компонент <code>sing-box</code> (~15 МБ) из интернета при установке.
      {#if !fullAvailable}<br /><em class="req">Недоступно: этот роутер не тянет VLESS+Reality
        (нужен более мощный) — будет использован AmneziaWG.</em>{/if}</span>
  </label>

  {#if protocol === 'reality' && fullAvailable}
    <label>
      <span>VLESS+Reality — ссылка или конфиг</span>
      <textarea
        bind:value={realityConf}
        rows="6"
        placeholder="vless://uuid@host:443?security=reality&pbk=…&sni=…&sid=…&flow=xtls-rprx-vision#name&#10;…или JSON-конфиг sing-box"
      ></textarea>
      <small class="muted">Возьмите ссылку из панели своего Reality-сервера (3x-ui / Hiddify и т.п.).
        Компонент <code>sing-box</code> скачается автоматически во время установки.</small>
    </label>
  {:else}
    <label>
      <span>VPN-конфиг (AmneziaWG, файл <code>.conf</code>)</span>
      <textarea
        bind:value={awgConf}
        rows="8"
        placeholder="[Interface]&#10;PrivateKey = …&#10;Address = …&#10;[Peer]&#10;PublicKey = …&#10;Endpoint = host:port"
      ></textarea>
      <small class="muted">Его выдаёт ваш VPN-провайдер (конфиг «для роутеров») или ваш собственный сервер.</small>
    </label>
    <label class="file">
      <span>…или загрузить файлом</span>
      <input type="file" accept=".conf,text/plain" onchange={onFile} />
    </label>
  {/if}

  <label>
    <span>Сайты напрямую, без VPN</span>
    <textarea
      bind:value={domainsText}
      rows="3"
      placeholder="ru&#10;example.com"
    ></textarea>
    <small class="muted">Эти сайты (домены) открываются напрямую; весь остальной трафик идёт
      через VPN. Одна запись зоны (например, <code>ru</code>) покрывает сразу все сайты в ней;
      отдельные сайты дописывайте своей строкой. Можно оставить как есть.</small>
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
    <h3>Wi-Fi {#if wifiRequired}<em class="req">(обязательно)</em>{:else}<em>(необязательно)</em>{/if}</h3>
    {#if wifiRequired}
      <p class="muted small">У этого роутера есть Wi-Fi — задайте имя сети и пароль, чтобы включить его.</p>
    {/if}
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

  {#if tokenEditable}
    <label>
      <span>Код установки</span>
      <input type="text" bind:value={token} placeholder="напечатан в терминале после команды установки" />
      <small class="muted">Он печатается в терминале сразу после команды установки — вставьте его сюда.</small>
    </label>
  {:else}
    <p class="muted small">✓ Код установки получен из ссылки.
      <button class="linklike" type="button" onclick={() => (tokenEditable = true)}>Изменить</button>
    </p>
  {/if}

  {#if error}<p class="warn">{error}</p>{/if}

  <div class="row">
    <button onclick={onBack}>Назад</button>
    <button class="primary" onclick={submit}>Установить</button>
  </div>
</section>
