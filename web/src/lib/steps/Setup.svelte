<script>
  // Props: onSubmit(args для install) / onBack; wirelessPresent (false → без Wi-Fi, null → необязателен);
  // initial («Назад» не теряет введённое); dnsProviders/dnsProviderDefault (каталог из status);
  // acceptRisk (soft-провалы preflight приняты — флаг едет в install). Туннель — только AmneziaWG (ADR 0010).
  import { MIN_PASS, SSID_MAX, WIFI_KEY_MIN, validateSetup, checkConf, PROTOCOLS } from '../logic.js';
  import * as Card from '$lib/components/ui/card/index.js';
  import * as Alert from '$lib/components/ui/alert/index.js';
  import Button from '$lib/components/ui/button/button.svelte';
  import Input from '$lib/components/ui/input/input.svelte';
  import Textarea from '$lib/components/ui/textarea/textarea.svelte';
  import NativeSelect from '$lib/components/ui/native-select/native-select.svelte';
  import Field from '$lib/components/Field.svelte';
  import ConfCheck from '$lib/components/ConfCheck.svelte';
  import DetailsGroup from '$lib/components/DetailsGroup.svelte';
  import FileButton from '$lib/components/FileButton.svelte';
  import StatusIcon from '$lib/components/StatusIcon.svelte';
  import * as F from '$lib/components/ui/field/index.js';
  import * as Item from '$lib/components/ui/item/index.js';
  import KeyRound from '@lucide/svelte/icons/key-round';
  import LockKeyhole from '@lucide/svelte/icons/lock-keyhole';
  import Wifi from '@lucide/svelte/icons/wifi';
  import Globe from '@lucide/svelte/icons/globe';
  import Filter from '@lucide/svelte/icons/filter';
  import Check from '@lucide/svelte/icons/check';

  let { onSubmit, onBack, wirelessPresent = null, dnsProviders = [], dnsProviderDefault = '', acceptRisk = false, urlToken = '', initial = null } = $props();

  // Показываем Wi-Fi везде, кроме точно-нет-радио. Обязателен только при точно-есть-радио.
  const showWifi = $derived(wirelessPresent !== false);
  const wifiRequired = $derived(wirelessPresent === true);

  // Посев из initial намеренно одноразовый: «Назад» с подтверждения пересоздаёт компонент,
  // и поля должны вернуть ранее введённое, а не следить за пропом.
  // svelte-ignore state_referenced_locally
  let confs = $state({ awg: initial?.awg_conf ?? '' });
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

  const active = PROTOCOLS.awg;

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
      confs,
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
    <Card.Description>Три вещи: VPN-конфиг, пароль роутера и Wi-Fi. Остальное уже настроено за вас.</Card.Description>
  </Card.Header>

  {#if acceptRisk}
    <Alert.Root variant="warning">
      <StatusIcon tone="warn" />
      <Alert.Body>
        <Alert.Description>
          Установка идёт на роутер слабее рекомендуемого — по вашему решению.
          Стабильность не гарантируем; при сбое изменения откатятся автоматически.
        </Alert.Description>
      </Alert.Body>
    </Alert.Root>
  {/if}

  <F.Group>
    <F.Set>
      <F.Legend class="flex items-center gap-2"><KeyRound class="size-4 text-primary" aria-hidden="true" />Подключение к VPN</F.Legend>
      <Field label={active.confLabel} bind:el={fieldEls.conf}>
        <Textarea
          bind:value={confs[active.id]}
          class="font-mono"
          rows={active.file ? 6 : 5}
          placeholder={active.placeholder}
          aria-invalid={errorField === 'conf'}
        />
        <ConfCheck id={active.id} text={confs[active.id]} hint={active.confHint} />
        {#if !(confs[active.id] ?? '').trim()}
          <F.Description>Нет ни подписки, ни сервера?
            <a href="https://github.com/andreiyurik/cheburnet-router#что-нужно-и-сколько-стоит"
              target="_blank" rel="noreferrer">Как получить — за 10–15 минут</a></F.Description>
        {/if}
      </Field>
      {#if active.file}
        <FileButton accept=".conf,text/plain" onchange={onFile}>Загрузить файл .conf</FileButton>
      {/if}
    </F.Set>

    <F.Separator />

    <F.Set>
      <F.Legend class="flex items-center gap-2"><LockKeyhole class="size-4 text-primary" aria-hidden="true" />Пароль роутера</F.Legend>
      <F.Description>Им вы входите в панель управления и в роутер по SSH. Запомните его.</F.Description>
      <Field label="Пароль администратора (root)" bind:el={fieldEls.rootPass}>
        <Input type="password" bind:value={rootPass} autocomplete="new-password"
               placeholder="минимум {MIN_PASS} символов" aria-invalid={errorField === 'rootPass'} />
      </Field>
      <Field label="Повторите пароль" bind:el={fieldEls.rootPass2}
             error={passMismatch ? 'Пароли не совпадают.' : ''}>
        <Input type="password" bind:value={rootPass2} autocomplete="new-password" placeholder="ещё раз тот же пароль"
               aria-invalid={errorField === 'rootPass2' || passMismatch}
               onblur={() => (pass2Left = true)} />
      </Field>
    </F.Set>

    {#if showWifi}
      <F.Separator />
      <F.Set>
        <F.Legend class="flex items-center gap-2"><Wifi class="size-4 text-primary" aria-hidden="true" />Wi-Fi</F.Legend>
        {#if wifiRequired}
          <F.Description>У этого роутера есть Wi-Fi — задайте имя сети и пароль, чтобы включить его.</F.Description>
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
          <F.Description>Не удалось узнать, есть ли у роутера Wi-Fi — заполните, если он есть; иначе оставьте пустым.</F.Description>
        {/if}
      </F.Set>
    {/if}
  </F.Group>

  <!-- Дефолты, которые трогают редко, — строками-итогами: видно значение, правка по нажатию. -->
  <Item.Group class="overflow-hidden rounded-lg border border-border divide-y divide-border">
    <DetailsGroup icon={Globe} summary="Сайты напрямую"
                  description="{domainsText.split('\n').filter((d) => d.trim()).length} шт. — изменить">
      <Field label="Сайты напрямую"
             hint="Остальное — через туннель. Домен (example.com) покрывает и все его поддомены, каждый сайт — своей строкой.">
        <Textarea bind:value={domainsText} rows="3" placeholder={'example.com\nexample.org'} />
      </Field>
    </DetailsGroup>
    {#if dnsProviders.length > 0}
      <DetailsGroup icon={Filter} summary="Фильтрация"
                    description={dnsProviders.find((p) => p.id === dnsProvider)?.name ?? '—'}>
        <Field label="Блокировка рекламы / взрослого контента"
               hint="«Семейный» провайдер дополнительно блокирует сайты 18+ и включает безопасный поиск.">
          <NativeSelect bind:value={dnsProvider}>
            {#each dnsProviders as p}
              <option value={p.id}>{p.name} — {p.description}</option>
            {/each}
          </NativeSelect>
        </Field>
      </DetailsGroup>
    {/if}
    {#if !tokenEditable}
      <Item.Root>
        <Item.Media variant="icon" class="text-success"><Check /></Item.Media>
        <Item.Content>
          <Item.Title class="text-base font-semibold">Код установки получен из ссылки</Item.Title>
        </Item.Content>
        <Item.Actions><Button variant="ghost" size="sm" onclick={() => (tokenEditable = true)}>Изменить</Button></Item.Actions>
      </Item.Root>
    {/if}
  </Item.Group>

  {#if tokenEditable}
    <Field label="Код установки" bind:el={fieldEls.token}
           hint="Проще: откройте в браузере всю ссылку из терминала (начинается на http://192.168.1.1/cheburnet/?token=…) — код уже в ней, вводить вручную не придётся.">
      <Input type="text" bind:value={token} placeholder="напечатан в терминале после команды установки"
             aria-invalid={errorField === 'token'} />
    </Field>
  {/if}

  {#if error}<F.Error>{error}</F.Error>{/if}

  <Card.Footer class="border-t border-border">
    <Button variant="outline" class="flex-1" onclick={onBack}>Назад</Button>
    <Button size="lg" class="flex-[2]" onclick={submit}>Установить</Button>
  </Card.Footer>
</Card.Root>
