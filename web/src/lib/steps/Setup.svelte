<script>
  // onSubmit(args) — args для метода install: { protocol, <conf_key>, root_password, [ssid,
  // wifi_key], domains, token }. onBack — вернуться на preflight.
  // wirelessPresent — есть ли радио (из status): false → скрыть Wi-Fi; true → обязателен;
  // null (статус не ответил) → показать как необязательный.
  // initial — ранее собранные args («Назад» с экрана подтверждения не теряет введённое).
  // dnsProviders — каталог фильтрующих DNS (из status); dnsProviderDefault — дефолтный id.
  // fullAvailable — ТЯНЕТ ли железо Full-тир (из preflight.tiers.full): true → доступны
  // VLESS+Reality и Hysteria2 (компонент догрузится автоматически при установке); false →
  // их строки показаны НЕактивными с пояснением про требования (образовательно), выбрать нельзя.
  // acceptRisk — пользователь прошёл экран проверки с непройденными soft-требованиями («всё равно
  // установить»): напоминаем об этом и несём флаг в аргументы install (движок проверит ещё раз).
  // fullReasons — ПОЧЕМУ Full-протоколы недоступны (из preflight.tiers.full_checks): человек
  // должен видеть «не хватает RAM», а не безликое «недоступно».
  //
  // ГЛАВНОЕ В ЭТОМ ЭКРАНЕ: выбор туннеля идёт ОТ СИМПТОМА, а не от названий протоколов. Человек
  // не знает, что такое DPI и QUIC, но точно знает, что у него не работает. Тексты — в каталоге
  // PROTOCOLS (logic.js), здесь только разметка.
  import { MIN_PASS, SSID_MAX, WIFI_KEY_MIN, validateSetup, BRUTAL_WARNING,
           protocolList, protocolInfo, defaultProtocol, SPEED_DEFAULTS } from '../logic.js';

  let { onSubmit, onBack, wirelessPresent = null, dnsProviders = [], dnsProviderDefault = '', fullAvailable = false, fullReasons = [], acceptRisk = false, urlToken = '', initial = null } = $props();

  // Показываем Wi-Fi везде, кроме точно-нет-радио. Обязателен только при точно-есть-радио.
  const showWifi = $derived(wirelessPresent !== false);
  const wifiRequired = $derived(wirelessPresent === true);

  const protocols = protocolList();

  // Посев из initial намеренно одноразовый: «Назад» с подтверждения пересоздаёт компонент,
  // и поля должны вернуть ранее введённое, а не следить за пропом.
  // Дефолт: на Full-железе — VLESS+Reality (закрывает самую частую поломку «VPN не поднимается»),
  // на слабом — AmneziaWG без выбора. См. defaultProtocol и ADR 0004.
  // svelte-ignore state_referenced_locally
  let protocol = $state(initial?.protocol ?? defaultProtocol(fullAvailable));
  // Конфиги хранятся ПО ПРОТОКОЛАМ: переключение радио не теряет уже вставленное (человек может
  // сравнить два варианта, не набирая заново).
  // svelte-ignore state_referenced_locally
  let confs = $state({
    awg: initial?.awg_conf ?? '',
    reality: initial?.reality_conf ?? '',
    hysteria2: initial?.hysteria2_conf ?? '',
  });
  // Brutal (Hysteria2): по умолчанию скорость НЕ объявляем — sing-box тогда использует BBR и
  // подстраивается сам. Ручной режим включается осознанно, см. предупреждение в разметке.
  let declareSpeed = $state(false);
  let speedDown = $state(SPEED_DEFAULTS.down);
  let speedUp = $state(SPEED_DEFAULTS.up);
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

  const active = $derived(protocolInfo(protocol));

  // Загрузка конфига файлом — только у протоколов с `file: true` (.conf у AmneziaWG; ссылку
  // файлом не приносят). Пишем в АКТИВНЫЙ протокол, а не в awg жёстко: иначе появление второго
  // файлового протокола молча уводило бы файл не в то поле.
  async function onFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    confs[active.id] = await f.text();
  }

  // Валидация и сборка аргументов install — чистая validateSetup (logic.js, под vitest).
  function submit() {
    error = '';
    const r = validateSetup({
      protocol, fullAvailable, confs, declareSpeed, speedDown, speedUp,
      rootPass, rootPass2, showWifi, wifiRequired, ssid, wifiKey,
      dnsProvider, domainsText, token, acceptRisk,
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

  {#if acceptRisk}
    <p class="note">Установка идёт на роутер слабее рекомендуемого — по вашему решению.
      Стабильность не гарантируем; при сбое изменения откатятся автоматически.</p>
  {/if}

  <h3>Каким туннелем пользоваться</h3>
  <p class="muted small">Ошибиться не страшно — туннель меняется потом из панели.</p>

  {#each protocols as p}
    {@const locked = p.full && !fullAvailable}
    <label class="radio" class:disabled={locked}>
      <input type="radio" bind:group={protocol} value={p.id} disabled={locked} />
      <span><strong>{p.symptom}</strong>{#if locked}<span class="badge-locked">недоступно</span>{/if} — {p.why}
        <!-- &nbsp; намеренно: Svelte срезает ведущий пробел внутри {#if}, и получалось
             «VLESS+Reality· недоступен». -->
        <br /><small class="muted">Протокол: {p.name}{#if locked}&nbsp;· недоступен на этом роутере{/if}</small></span>
    </label>
  {/each}

  <!-- Причина — ОДНА строка под списком, а не под каждой запертой строкой: она общая для обоих
       Full-протоколов, и продублированная жирным дважды была самым заметным текстом на экране,
       где человек вообще-то выбирает туннель. -->
  {#if !fullAvailable && fullReasons.length > 0}
    <p class="muted small">Почему недоступны: {fullReasons.join('; ')}.</p>
  {/if}

  <details class="more">
    <summary>Чем они отличаются подробнее</summary>
    <ul class="small">
      {#each protocols as p}
        <li><strong>{p.name}</strong> — {p.whyMore}</li>
      {/each}
    </ul>
  </details>

  {#if fullAvailable}
    <p class="muted small">Для VLESS+Reality и Hysteria2 нужен компонент <code>sing-box</code> —
      он скачается сам во время установки (~11 МБ).</p>
  {/if}

  <label>
    <span>{active.confLabel}</span>
    <textarea
      bind:value={confs[active.id]}
      rows={active.file ? 8 : 6}
      placeholder={active.placeholder}
    ></textarea>
    <small class="muted">{active.confHint}</small>
  </label>
  {#if active.file}
    <label class="file">
      <span>…или загрузить файлом</span>
      <input type="file" accept=".conf,text/plain" onchange={onFile} />
    </label>
  {/if}

  <!-- Brutal только у Hysteria2. Голое поле «Мбит/с» здесь было бы вредным: завышенное значение
       раздувает очередь и делает связь ХУЖЕ, причём молча — ошибок в логах не будет. Поэтому
       по умолчанию режим автоматический, а ручной снабжён прямым предупреждением. -->
  {#if protocol === 'hysteria2'}
    <h3>Скорость канала</h3>
    <label class="radio">
      <input type="radio" bind:group={declareSpeed} value={false} />
      <span><strong>Подбирать автоматически</strong> — рекомендуем. Туннель сам определяет,
        сколько может взять, и подстраивается под канал.</span>
    </label>
    <label class="radio">
      <input type="radio" bind:group={declareSpeed} value={true} />
      <span><strong>Указать вручную</strong> — иногда выжимает больше на канале с потерями,
        но только если цифры честные.</span>
    </label>
    {#if declareSpeed}
      <p class="warn">{BRUTAL_WARNING} Не знаете точных цифр — выберите «автоматически».</p>
      <label>
        <span>Скорость приёма (Мбит/с)</span>
        <input type="number" min="1" max="10000" bind:value={speedDown} />
      </label>
      <label>
        <span>Скорость отдачи (Мбит/с)</span>
        <input type="number" min="1" max="10000" bind:value={speedUp} />
      </label>
    {/if}
  {/if}

  <label>
    <span>Сайты напрямую</span>
    <textarea
      bind:value={domainsText}
      rows="3"
      placeholder="ru&#10;example.com"
    ></textarea>
    <small class="muted">Остальное — через туннель. Запись зоны (<code>ru</code>) покрывает все
      сайты в ней; отдельные — своей строкой.</small>
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
      <small class="muted">WPA2/WPA3 (если доступно).</small>
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
      <small class="muted">«Семейный» провайдер дополнительно блокирует сайты 18+ и форсит безопасный поиск.</small>
    </label>
  {/if}

  {#if tokenEditable}
    <label>
      <span>Код установки</span>
      <input type="text" bind:value={token} placeholder="напечатан в терминале после команды установки" />
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
