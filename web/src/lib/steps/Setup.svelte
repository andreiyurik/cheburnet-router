<script>
  // Props: onSubmit(args для install) / onBack; wirelessPresent (false → без Wi-Fi, null → необязателен);
  // initial («Назад» не теряет введённое); dnsProviders/dnsProviderDefault (каталог из status);
  // fullAvailable (железо тянет Full → доступны Reality/Hysteria2, иначе строки неактивны с причиной
  // из fullReasons); acceptRisk (soft-провалы preflight приняты — флаг едет в install).
  // ГЛАВНОЕ: выбор туннеля идёт ОТ СИМПТОМА, не от названий протоколов — тексты в PROTOCOLS (logic.js).
  import { MIN_PASS, SSID_MAX, WIFI_KEY_MIN, validateSetup, BRUTAL_WARNING, checkConf,
           protocolList, protocolInfo, defaultProtocol, SPEED_DEFAULTS } from '../logic.js';
  import * as Card from '$lib/components/ui/card/index.js';
  import * as Alert from '$lib/components/ui/alert/index.js';
  import Button from '$lib/components/ui/button/button.svelte';
  import Input from '$lib/components/ui/input/input.svelte';
  import Textarea from '$lib/components/ui/textarea/textarea.svelte';
  import NativeSelect from '$lib/components/ui/native-select/native-select.svelte';
  import RadioCard from '$lib/components/ui/radio-card/radio-card.svelte';
  import Badge from '$lib/components/ui/badge/badge.svelte';
  import Field from '$lib/components/Field.svelte';
  import SectionTitle from '$lib/components/SectionTitle.svelte';
  import ConfCheck from '$lib/components/ConfCheck.svelte';

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
  let errorField = $state(''); // виновное поле из validateSetup — подсветка + прокрутка
  const fieldEls = {}; // DOM-узлы полей по имени (bind:el), для scrollIntoView

  // Живые подсказки до сабмита. Показываем после ухода из поля (blur) либо когда второй пароль
  // догнал первый по длине — иначе «не совпадают» дёргается на каждой набранной букве.
  let pass2Left = $state(false);
  let wifiKeyLeft = $state(false);
  const passMismatch = $derived(
    rootPass2.length > 0 && rootPass2 !== rootPass && (pass2Left || rootPass2.length >= rootPass.length)
  );
  const wifiKeyShort = $derived(wifiKeyLeft && wifiKey.length > 0 && wifiKey.length < WIFI_KEY_MIN);

  const active = $derived(protocolInfo(protocol));

  // Живые проверки снимают подсветку прошлого сабмита, как только поле исправлено, — иначе
  // зелёная галка ConfCheck соседствует с красной рамкой.
  $effect(() => {
    if (errorField === 'conf' && (confs[active.id] ?? '').trim()
        && !checkConf(active.id, confs[active.id].trim())) errorField = '';
  });
  $effect(() => {
    if (errorField === 'rootPass2' && rootPass === rootPass2) errorField = '';
  });

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
    errorField = '';
    const r = validateSetup({
      protocol, fullAvailable, confs, declareSpeed, speedDown, speedUp,
      rootPass, rootPass2, showWifi, wifiRequired, ssid, wifiKey,
      dnsProvider, domainsText, token, acceptRisk,
    });
    if (r.error) {
      error = r.error;
      errorField = r.field ?? '';
      fieldEls[errorField]?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      return;
    }
    onSubmit(r.args);
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Настройка</Card.Title>
  </Card.Header>

  <Card.Content>
    {#if acceptRisk}
      <Alert.Root variant="warning">
        <Alert.Description>
          Установка идёт на роутер слабее рекомендуемого — по вашему решению.
          Стабильность не гарантируем; при сбое изменения откатятся автоматически.
        </Alert.Description>
      </Alert.Root>
    {/if}

    <div>
      <SectionTitle>Каким туннелем пользоваться</SectionTitle>
      <p class="mt-2 text-sm text-muted-foreground">Ошибиться не страшно — туннель меняется потом из панели.</p>

      {#each protocols as p}
        {@const locked = p.full && !fullAvailable}
        <RadioCard bind:group={protocol} value={p.id} disabled={locked}>
          <strong>{p.symptom}</strong> — {p.why}
          <br /><span class="mt-1 flex items-center gap-2 text-sm text-muted-foreground">
            Протокол: {p.name}{#if locked}<Badge variant="warning">недоступно</Badge>{/if}
          </span>
        </RadioCard>
      {/each}

      <!-- Причина — ОДНА строка под списком, а не под каждой запертой строкой: она общая для обоих
           Full-протоколов, и продублированная жирным дважды была самым заметным текстом на экране,
           где человек вообще-то выбирает туннель. -->
      {#if !fullAvailable && fullReasons.length > 0}
        <p class="text-sm text-muted-foreground">Почему недоступны: {fullReasons.join('; ')}.</p>
      {/if}

      <details class="mt-3">
        <summary class="cursor-pointer text-sm text-muted-foreground">Чем они отличаются подробнее</summary>
        <ul class="mt-2 list-disc pl-5 text-sm text-muted-foreground">
          {#each protocols as p}
            <li><strong class="text-foreground">{p.name}</strong> — {p.whyMore}</li>
          {/each}
        </ul>
      </details>

      {#if fullAvailable}
        <p class="mt-3 text-sm text-muted-foreground">Для VLESS+Reality и Hysteria2 компонент
          <code class="rounded-sm bg-muted px-1 py-0.5 font-mono">sing-box</code> (~11 МБ) скачается сам.</p>
      {/if}
    </div>

    <Field label={active.confLabel} bind:el={fieldEls.conf}>
      <Textarea
        bind:value={confs[active.id]}
        class="font-mono"
        rows={active.file ? 8 : 6}
        placeholder={active.placeholder}
        aria-invalid={errorField === 'conf'}
      />
      <ConfCheck id={active.id} text={confs[active.id]} hint={active.confHint} />
      {#if !(confs[active.id] ?? '').trim()}
        <span class="mt-1.5 block text-sm text-muted-foreground">Нет ни подписки, ни сервера?
          <a href="https://github.com/andreiyurik/cheburnet-router#что-нужно-и-сколько-стоит"
            target="_blank" rel="noreferrer">Как получить — за 10–15 минут</a></span>
      {/if}
    </Field>
    {#if active.file}
      <Field label="…или загрузить файлом">
        <Input type="file" accept=".conf,text/plain" onchange={onFile} />
      </Field>
    {/if}

    <!-- Brutal только у Hysteria2. Голое поле «Мбит/с» здесь было бы вредным: завышенное значение
         раздувает очередь и делает связь ХУЖЕ, причём молча — ошибок в логах не будет. Поэтому
         по умолчанию режим автоматический, а ручной снабжён прямым предупреждением. -->
    {#if protocol === 'hysteria2'}
      <div>
        <SectionTitle>Скорость канала</SectionTitle>
        <RadioCard bind:group={declareSpeed} value={false}>
          <strong>Подбирать автоматически</strong> — рекомендуем. Туннель сам определяет,
          сколько может взять, и подстраивается под канал.
        </RadioCard>
        <RadioCard bind:group={declareSpeed} value={true}>
          <strong>Указать вручную</strong> — иногда выжимает больше на канале с потерями,
          но только если цифры честные.
        </RadioCard>
        {#if declareSpeed}
          <Alert.Root variant="warning" class="my-3">
            <Alert.Description>{BRUTAL_WARNING} Не знаете точных цифр — выберите «автоматически».</Alert.Description>
          </Alert.Root>
          <Field label="Скорость приёма (Мбит/с)" bind:el={fieldEls.speed} class="mb-3">
            <Input type="number" min="1" max="10000" class="w-32" bind:value={speedDown} aria-invalid={errorField === 'speed'} />
          </Field>
          <Field label="Скорость отдачи (Мбит/с)">
            <Input type="number" min="1" max="10000" class="w-32" bind:value={speedUp} aria-invalid={errorField === 'speed'} />
          </Field>
        {/if}
      </div>
    {/if}

    <details class="border-t border-border pt-3">
      <summary class="cursor-pointer text-sm">
        Сайты напрямую: <strong>{domainsText.split('\n').filter((d) => d.trim()).length} шт.</strong>
        <span class="text-muted-foreground">— изменить</span>
      </summary>
      <Field class="mt-3" label="Сайты напрямую"
             hint="Остальное — через туннель. Запись зоны (ru) покрывает все сайты в ней; отдельные — своей строкой.">
        <Textarea bind:value={domainsText} rows="3" placeholder={'ru\nexample.com'} />
      </Field>
    </details>

    <div class="flex flex-col gap-4">
      <SectionTitle>Пароль роутера</SectionTitle>
      <Field label="Пароль администратора (root)" bind:el={fieldEls.rootPass}
             hint="Им вы входите в роутер по SSH и в панель управления. Запомните его.">
        <Input type="password" bind:value={rootPass} autocomplete="new-password"
               placeholder="минимум {MIN_PASS} символов" aria-invalid={errorField === 'rootPass'} />
      </Field>
      <Field label="Повторите пароль" bind:el={fieldEls.rootPass2}
             error={passMismatch ? 'Пароли не совпадают.' : ''}>
        <Input type="password" bind:value={rootPass2} autocomplete="new-password" placeholder="ещё раз тот же пароль"
               aria-invalid={errorField === 'rootPass2' || passMismatch}
               onblur={() => (pass2Left = true)} />
      </Field>
    </div>

    {#if showWifi}
      <div class="flex flex-col gap-4">
        <SectionTitle>Wi-Fi</SectionTitle>
        {#if wifiRequired}
          <p class="text-sm text-muted-foreground">У этого роутера есть Wi-Fi — задайте имя сети и пароль, чтобы включить его.</p>
        {/if}
        <Field label="Имя сети (SSID)" bind:el={fieldEls.ssid} required={wifiRequired} optional={!wifiRequired}>
          <Input type="text" bind:value={ssid} maxlength={SSID_MAX} placeholder="например, MyHome"
                 aria-invalid={errorField === 'ssid'} />
        </Field>
        <Field label="Пароль Wi-Fi" bind:el={fieldEls.wifiKey}
               required={wifiRequired} optional={!wifiRequired}
               hint="WPA2/WPA3 (если доступно)."
               error={wifiKeyShort ? `Минимум ${WIFI_KEY_MIN} символов — сейчас ${wifiKey.length}.` : ''}>
          <Input type="password" bind:value={wifiKey} autocomplete="new-password"
                 placeholder="минимум {WIFI_KEY_MIN} символов"
                 aria-invalid={errorField === 'wifiKey' || wifiKeyShort}
                 onblur={() => (wifiKeyLeft = true)} />
        </Field>
        {#if wirelessPresent === null}
          <p class="text-sm text-muted-foreground">Не удалось узнать, есть ли у роутера Wi-Fi — заполните, если он есть; иначе оставьте пустым.</p>
        {/if}
      </div>
    {/if}

    {#if dnsProviders.length > 0}
      <details class="border-t border-border pt-3">
        <summary class="cursor-pointer text-sm">
          Фильтрация: <strong>{dnsProviders.find((p) => p.id === dnsProvider)?.name ?? '—'}</strong>
          <span class="text-muted-foreground">— изменить</span>
        </summary>
        <Field class="mt-3" label="Блокировка рекламы / взрослого контента"
               hint="«Семейный» провайдер дополнительно блокирует сайты 18+ и форсит безопасный поиск.">
          <NativeSelect bind:value={dnsProvider}>
            {#each dnsProviders as p}
              <option value={p.id}>{p.name} — {p.description}</option>
            {/each}
          </NativeSelect>
        </Field>
      </details>
    {/if}

    {#if tokenEditable}
      <Field label="Код установки" bind:el={fieldEls.token}
             hint="Проще: откройте в браузере всю ссылку из терминала (начинается на http://192.168.1.1/cheburnet/?token=…) — код уже в ней, вводить вручную не придётся.">
        <Input type="text" bind:value={token} placeholder="напечатан в терминале после команды установки"
               aria-invalid={errorField === 'token'} />
      </Field>
    {:else}
      <p class="text-sm text-muted-foreground">✓ Код установки получен из ссылки.
        <Button variant="link" onclick={() => (tokenEditable = true)}>Изменить</Button>
      </p>
    {/if}

    {#if error}<p class="text-destructive">{error}</p>{/if}

    <div class="flex flex-wrap gap-3">
      <Button variant="outline" class="min-w-35 flex-1" onclick={onBack}>Назад</Button>
      <Button size="lg" class="min-w-35 flex-1" onclick={submit}>Установить</Button>
    </div>
  </Card.Content>
</Card.Root>
