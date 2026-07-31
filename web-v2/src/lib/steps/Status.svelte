<script>
  import { onDestroy } from 'svelte';
  import { cheburnet, login, isLoggedIn, logout } from '../ubus.js';
  import { hs, FORCED_LABELS, heroKind, tunnelFallback, switchTargets, tunnelRowText,
           explainFullTierFail, fullMissingText, protocolInfo,
           withDeclaredSpeed, SPEED_DEFAULTS } from '../logic.js';

  // onReinstall — запустить мастер заново (с preflight).
  let { onReinstall } = $props();

  let s = $state(null);
  let error = $state('');
  let action = $state(''); // текст результата/ошибки управляющего действия
  let busy = $state(false);
  // Замена сервера АКТИВНОГО туннеля: одно поле, метод и подпись — из каталога протоколов.
  let replaceConf = $state('');
  let replacePhase = $state('idle'); // idle | running | ok | fail
  let replaceLog = $state('');
  let resetWord = $state('');
  let resetArmed = $state(false);
  let fullPhase = $state('idle'); // догрузка компонента: idle | running | ok | fail
  let fullLog = $state('');
  // Смена туннеля: конфиги хранятся ПО ПРОТОКОЛАМ (переключение блоков не теряет вставленное).
  let switchConfs = $state({ awg: '', reality: '', hysteria2: '' });
  let switchTarget = $state('');  // направление текущего свитча
  let switchPhase = $state('idle');
  let switchLog = $state('');
  // Скорость канала для Hysteria2 (Brutal). По умолчанию — автоматически (BBR): см. logic.js.
  let declareSpeed = $state(false);
  let speedDown = $state(SPEED_DEFAULTS.down);
  let speedUp = $state(SPEED_DEFAULTS.up);
  let timer = null;
  let replaceTimer = null;
  let fullTimer = null;
  let switchTimer = null;

  // Вход (admin-сессия root). Лимит 3 попытки — дальше отсылаем к SSH.
  const MAX_LOGIN_ATTEMPTS = 3;
  let loggedIn = $state(isLoggedIn());
  let loginOpen = $state(false);
  let loginPass = $state('');
  let loginError = $state('');
  let loginAttempts = $state(0);

  async function refresh() {
    try {
      s = await cheburnet('status');
      if (!providerSel && s.dns_provider) providerSel = s.dns_provider;
      error = '';
    } catch (e) {
      error = e.message;
    }
  }

  // Управляющие действия — admin-методы. Без сессии (или с протухшей) ubus отдаёт
  // PERMISSION_DENIED — открываем модалку входа, а не показываем голую ошибку.
  async function admin(label, fn) {
    busy = true;
    action = '';
    try {
      await fn();
      action = `${label} — готово.`;
      await refresh();
    } catch (e) {
      if (e.message.includes('PERMISSION_DENIED')) {
        logout(); // протухшую сессию выбрасываем
        loggedIn = false;
        loginOpen = true;
        action = `${label}: нужен вход — введите пароль роутера.`;
      } else {
        action = `${label}: ${e.message}`;
      }
    } finally {
      busy = false;
    }
  }

  // needLogin(e, what) — общая обработка PERMISSION_DENIED для фоновых операций (они не идут
  // через admin(), потому что там свой поллинг прогресса).
  function needLogin(e, what) {
    busy = false;
    if (e.message.includes('PERMISSION_DENIED')) {
      logout(); loggedIn = false; loginOpen = true;
      action = `${what}: нужен вход — введите пароль роутера.`;
    } else {
      action = `${what}: ${e.message}`;
    }
  }

  async function doLogin() {
    loginError = '';
    try {
      await login(loginPass);
      loggedIn = true;
      loginOpen = false;
      loginPass = '';
      loginAttempts = 0;
      action = 'Вход выполнен — повторите действие.';
    } catch (e) {
      loginAttempts += 1;
      loginPass = '';
      loginError = loginAttempts >= MAX_LOGIN_ATTEMPTS
        ? 'Пароль не подошёл. Нужен пароль, заданный при установке роутера. Перезагрузите страницу и попробуйте снова — или обратитесь к тому, кто настраивал роутер.'
        : `Пароль не подошёл (попытка ${loginAttempts} из ${MAX_LOGIN_ATTEMPTS}). Нужен пароль, заданный при установке роутера.`;
    }
  }

  function doLogout() {
    logout();
    loggedIn = false;
    action = 'Вы вышли — управление снова требует входа.';
  }

  const setMode = (mode) => admin(`Режим ${mode}`, () => cheburnet('set_mode', { mode }));
  const updateList = () =>
    admin('Обновление списка', async () => {
      const r = await cheburnet('update_list');
      action = `Список обновлён: ${r.direct_domains} доменов.`;
    });
  const restart = (service, label) =>
    admin(`Перезапуск: ${label}`, () => cheburnet('service_restart', { service }));
  // DNS-провайдер = уровень фильтрации (реклама/семейный/без). Выбор из каталога (status.dns_providers).
  let providerSel = $state('');

  // Главный сигнал панели и запасной путь — чистые функции (logic.js, под vitest). hero знает,
  // ЧЕМ мерить каждый протокол; fallback — куда вести, если активный туннель не поднимается.
  const hero = $derived(heroKind(s));
  const active = $derived(protocolInfo(s?.protocol));
  const fallback = $derived(tunnelFallback(s));
  const targets = $derived(switchTargets(s));
  // Чего не хватает железу для Full-тира (status.full_missing) — человеческими словами.
  const fullMissing = $derived(fullMissingText(s?.full_missing));
  const setProvider = () =>
    admin(`DNS-провайдер: ${providerSel}`, () => cheburnet('set_dns_provider', { provider: providerSel }));

  // Загрузка .conf файлом (только у AmneziaWG — ссылку файлом не приносят).
  async function onReplaceFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    replaceConf = await f.text();
  }
  async function onSwitchFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    switchConfs.awg = await f.text();
  }

  // hy2Conf(id, conf) — ссылка Hysteria2 с объявленной скоростью, если владелец её включил.
  // Для остальных протоколов — как есть.
  function hy2Conf(id, conf) {
    return (id === 'hysteria2' && declareSpeed)
      ? withDeclaredSpeed(conf, speedDown, speedUp)
      : conf;
  }

  // Замена сервера активного туннеля: метод и имя аргумента — из каталога протоколов, поэтому
  // третий протокол не потребовал третьей копии этой функции. Фон+poll — общий канал
  // install_progress (тот же, что у установки).
  async function replaceTunnel() {
    const conf = replaceConf.trim();
    if (conf.length === 0) {
      action = `Вставьте ${active.confLabel.toLowerCase()}.`;
      return;
    }
    busy = true;
    action = '';
    replaceLog = '';
    try {
      await cheburnet(active.replaceMethod, { [active.confKey]: hy2Conf(active.id, conf) });
      replacePhase = 'running';
      replaceTimer = setInterval(pollReplace, 2000);
    } catch (e) {
      needLogin(e, 'Замена конфига');
    }
  }

  async function pollReplace() {
    try {
      const p = await cheburnet('install_progress');
      replaceLog = p.log ?? '';
      if (p.done) {
        clearInterval(replaceTimer);
        replaceTimer = null;
        busy = false;
        if (p.result === 'ok') {
          replacePhase = 'ok';
          replaceConf = '';
          action = `Новый сервер применён (${active.name}) — трафик идёт через туннель.`;
        } else {
          replacePhase = 'fail';
          // Честный намёк на случай, когда виноват не сервер, а сеть — иначе пользователь меняет
          // один конфиг на другой по кругу без понимания, почему все падают.
          action = 'Новый сервер тоже не отозвался — прежний возвращён автоматически. Проверьте, что '
            + 'конфиг свежий и сервер жив. Если несколько серверов подряд не работают, дело, скорее '
            + 'всего, не в них: попробуйте другой туннель — блок «Сменить туннель» ниже.';
        }
        await refresh();
      }
    } catch {
      // единичный сбой поллинга не валим — следующий тик повторит
    }
  }

  // Factory reset: двойное подтверждение — ввод слова RESET руками.
  const factoryReset = () =>
    admin('Сброс cheburnet', async () => {
      await cheburnet('factory_reset', { confirm: resetWord.trim() });
      action = 'Сброс запущен: конфигурация cheburnet снимается, роутер вернётся к обычной маршрутизации.';
      resetWord = '';
      resetArmed = false;
    });

  refresh();
  // 15 с, не чаще: каждый опрос — это спавн rpcd-скрипта + shell-батч на роутере (слабое железо).
  timer = setInterval(refresh, 15000);
  onDestroy(() => {
    if (timer) clearInterval(timer);
    if (replaceTimer) clearInterval(replaceTimer);
    if (fullTimer) clearInterval(fullTimer);
    if (switchTimer) clearInterval(switchTimer);
  });

  // In-place смена туннеля: приносим только конфиг нового туннеля, домены/DNS берутся из
  // сохранённого (мастер не проходим). run.uc делает snapshot → teardown прежнего → apply → health
  // → commit/rollback, прогресс — тот же канал install_progress. При сбое ПРЕЖНИЙ туннель
  // возвращается автоматически. Одна функция на все шесть переходов — метод берём из каталога.
  async function switchTo(p) {
    const conf = (switchConfs[p.id] ?? '').trim();
    if (conf.length === 0) {
      action = `Вставьте ${p.confLabel.toLowerCase()}.`;
      return;
    }
    switchTarget = p.id;
    busy = true; action = ''; switchLog = '';
    try {
      await cheburnet(p.switchMethod, { [p.confKey]: hy2Conf(p.id, conf) });
      switchPhase = 'running';
      switchTimer = setInterval(pollSwitch, 2000);
    } catch (e) {
      needLogin(e, 'Переключение');
    }
  }

  async function pollSwitch() {
    try {
      const p = await cheburnet('install_progress');
      switchLog = p.log ?? '';
      if (p.done) {
        clearInterval(switchTimer); switchTimer = null; busy = false;
        const to = protocolInfo(switchTarget).name;
        const from = active.name;
        if (p.result === 'ok') {
          switchPhase = 'ok';
          switchConfs[switchTarget] = '';
          action = `Переключено на ${to} — туннель работает.`;
        } else {
          switchPhase = 'fail';
          action = `Не удалось поднять ${to} — прежний туннель (${from}) возвращён автоматически. `
            + 'Проверьте, что конфиг вставлен целиком и сервер жив.';
        }
        await refresh();
      }
    } catch { /* единичный сбой поллинга — следующий тик повторит */ }
  }

  // Full-тир (opt-in): кнопка догружает компонент sing-box фоном. Прогресс — тот же канал
  // install_progress. Работающий туннель при этом не трогается (ставим только пакет).
  async function enableFullTier() {
    busy = true; action = ''; fullLog = '';
    try {
      await cheburnet('install_full_tier');
      fullPhase = 'running';
      fullTimer = setInterval(pollFull, 2000);
    } catch (e) {
      needLogin(e, 'Установка запасного туннеля');
    }
  }

  async function pollFull() {
    try {
      const p = await cheburnet('install_progress');
      fullLog = p.log ?? '';
      if (p.done) {
        clearInterval(fullTimer); fullTimer = null; busy = false;
        if (p.result === 'ok') {
          fullPhase = 'ok';
          action = 'Компонент установлен. Ниже появился блок «Сменить туннель» — вставьте туда ссылку от вашего сервера.';
        } else {
          fullPhase = 'fail';
          // Причина из движка (install-singbox.sh пишет REASON_FILE): совет «проверьте интернет»
          // на забитом флеше отправлял чинить не то, а компонент реально может не влезть.
          action = explainFullTierFail(p.reason);
        }
        await refresh();
      }
    } catch { /* единичный сбой поллинга — следующий тик повторит */ }
  }
</script>

<section>
  <h2>Состояние</h2>

  {#if error}<p class="warn">{error}</p>{/if}

  {#if s}
    <!-- Hero-статус: с ОДНОГО взгляда «всё работает / есть проблема + что делать». Здоровье
         туннеля даёт движок (status.tunnel_health) — он знает, чем мерить активный протокол;
         панель лишь подбирает формулировку и путь к починке (якоря блоков ниже). -->
    {#if hero === 'down'}
      <p class="banner">
        <strong>⚠️ Туннель не работает ({active.name}).</strong> Сайты, которые идут через VPN,
        сейчас недоступны — открываются только сайты из списка «напрямую». Что делать: попробуйте
        кнопку «Туннель» в «Перезапуск сервисов»; не помогло — <a href="#replace-tunnel">вставьте
        свежий конфиг</a> от своего сервера.
      </p>
      <!-- Ведём к запасному пути ровно в тот момент, когда он нужен, а не прячем его в конце
           страницы. ВАЖНО: с AmneziaWG предлагаем именно VLESS+Reality. Hysteria2 работает по
           UDP, как и AmneziaWG, поэтому сеть, которая режет UDP, ломает их вместе — предлагать
           его как замену «не открывается вообще» значило бы посылать человека по кругу. -->
      {#if fallback?.action === 'install'}
        <p class="note">
          Вставили свежий конфиг, а туннель всё равно не поднимается? Бывает, что сеть не пропускает
          сам протокол AmneziaWG — он работает по UDP. Тогда помогает запасной путь:
          <a href="#full-tier">добавить VLESS+Reality</a> — снаружи он выглядит как обычный HTTPS.
          Ставится один раз, AmneziaWG никуда не денется.
        </p>
      {:else if fallback?.action === 'switch'}
        <p class="note">
          Вставили свежий конфиг, а туннель всё равно не поднимается? Значит дело, скорее всего, не
          в сервере, а в сети. Компонент уже установлен — попробуйте другой туннель:
          {#each fallback.targets as t, i}{#if i > 0}, {/if}<a href="#switch-{t}">{protocolInfo(t).name}</a>{/each}.
          Переключение обратимо: если новый не поднимется, прежний вернётся сам.
        </p>
      {/if}
    {:else if hero === 'up' && active.full}
      <!-- Формулировка слабее, чем у AWG, ОСОЗНАННО: у Full-протоколов нет рукопожатия — мы видим,
           что туннель поднят, но не что сервер отвечает. Не обещаем «всё работает». -->
      <p class="ok-msg">✅ {active.name} активен: трафик идёт через туннель.</p>
      <p class="muted small">Если сайты всё же не открываются — сервер мог отключиться. Свежий
        конфиг вставляется ниже, прежний вернётся сам при неудаче.</p>
    {:else if hero === 'up'}
      <p class="ok-msg">✅ Всё работает: VPN активен, трафик защищён.</p>
    {/if}

    <!-- Тревожный (красный) баннер — ТОЛЬКО когда direct-доменов вообще нет: тогда split не
         работает и весь трафик реально идёт в туннель. Если у пользователя есть свои домены
         (direct_domains>0), они идут напрямую — красная тревога тут ложна и вводит в заблуждение. -->
    {#if s.installed && s.direct_domains === 0}
      <p class="banner">
        Список доменов прямого доступа пуст — сейчас весь трафик идёт через туннель (безопасно,
        но медленнее). Добавьте домены в мастере («Настроить заново») или подтяните готовый
        список кнопкой «Обновить список доменов».
      </p>
    {:else if s.installed && !s.direct_list_loaded}
      <!-- Необязательный community-список не подтянут — это НЕ проблема (свои домены работают).
           Нейтральная подсказка, не красная тревога. -->
      <p class="note">
        Работают ваши домены прямого доступа ({s.direct_domains}). Можно дополнительно подтянуть
        готовый список популярных доменов — кнопка «Обновить список доменов» ниже.
      </p>
    {/if}

    <!-- Роутер поставлен с пропуском проверок железа (install.json.forced). Плашка постоянная и
         нейтральная: это не поломка, но при разборе «тормозит/отваливается» она — первое, что
         должно быть видно (в том числе на скриншоте статуса от пользователя). -->
    {#if s.installed && s.forced?.length > 0}
      <p class="note">
        Роутер слабее рекомендуемого — установлено по вашему решению
        ({s.forced.map((f) => FORCED_LABELS[f] ?? f).join(', ')}). Работает, но стабильность
        не гарантируется: при странных перезагрузках или тормозах это первая причина, куда смотреть.
      </p>
    {/if}

    <ul class="status">
      <li><span>Режим</span><strong>{s.mode === 'travel' ? 'В поездке — весь трафик через VPN' : 'Дома — выбранные сайты напрямую'}</strong></li>
      <li><span>Сайты напрямую, без VPN</span><strong>{s.direct_domains}</strong></li>
      <li><span>Импортированный список</span><strong>{s.direct_list_loaded ? `${s.imported_domains} доменов` : 'не загружен'}</strong></li>
      <!-- Подпись зависит от протокола: у AWG видно, когда сервер отвечал; у Full-протоколов —
           только что туннель поднят (см. tunnelRowText). Цвет — из единого tunnel_health движка. -->
      <li class:ok={s.tunnel_health === 'up'} class:bad={s.tunnel_health !== 'up'}>
        <span>{active.full ? `Туннель (${active.name})` : 'VPN-сервер'}</span>
        <strong>{tunnelRowText(s)}</strong>
      </li>
      <li class:ok={s.dns_up} class:bad={!s.dns_up}><span>DNS</span><strong>{s.dns_up ? 'работает' : 'нет'}</strong></li>
      <li class:ok={s.doh_up} class:bad={!s.doh_up}><span>Шифрованный DNS</span><strong>{s.doh_up ? 'работает' : 'нет'}</strong></li>
      {#if s.wireless_present}
        <li><span>Wi-Fi (SSID)</span><strong>{s.ssid || '—'}</strong></li>
      {/if}
      <li><span>DNS-фильтрация</span><strong>{s.dns_provider_desc ? s.dns_provider_desc.name : (s.dns_provider ?? '—')}</strong></li>
    </ul>

    <h3>Управление</h3>
    <div class="row">
      <button disabled={busy} onclick={() => setMode(s.mode === 'travel' ? 'home' : 'travel')}>
        {s.mode === 'travel' ? 'Режим «Дома» — выбранные сайты напрямую' : 'Режим «В поездке» — весь трафик через VPN'}
      </button>
      <button disabled={busy} onclick={updateList}>Обновить список доменов</button>
    </div>

    <h3>Перезапуск сервисов</h3>
    <div class="row">
      <button disabled={busy} onclick={() => restart('vpn', 'туннель')}>Туннель</button>
      <button disabled={busy} onclick={() => restart('dns', 'DNS')}>DNS</button>
      <button disabled={busy} onclick={() => restart('doh', 'шифрованный DNS')}>Шифрованный DNS</button>
    </div>

    <h3>Фильтрация (DNS)</h3>
    <label>
      <span>Блокировка рекламы / взрослого контента</span>
      <select bind:value={providerSel} disabled={busy}>
        {#each s.dns_providers ?? [] as p}
          <option value={p.id}>{p.name} — {p.description}</option>
        {/each}
      </select>
    </label>
    <div class="row">
      <button disabled={busy || !providerSel || providerSel === s.dns_provider} onclick={setProvider}>Применить</button>
    </div>
    <p class="muted small">«Семейный» провайдер блокирует сайты 18+ и форсит безопасный поиск. Выбор провайдера = уровень фильтрации.</p>

    <!-- Замена сервера АКТИВНОГО туннеля. Метод, подпись и placeholder — из каталога протоколов. -->
    <h3 id="replace-tunnel">Замена сервера ({active.name})</h3>
    <p class="muted small">Если туннель перестал работать — возьмите свежий конфиг у своего
      провайдера или в панели своего сервера и вставьте здесь. Если новый сервер не отзовётся,
      прежний вернётся автоматически — сломать нельзя.</p>
    <label>
      <span>{active.confLabel}</span>
      <textarea bind:value={replaceConf} rows="5" disabled={busy}
        placeholder={active.placeholder}></textarea>
    </label>
    {#if active.file}
      <label class="file">
        <span>…или загрузить файлом</span>
        <input type="file" accept=".conf,text/plain" onchange={onReplaceFile} disabled={busy} />
      </label>
    {/if}
    <div class="row">
      <button disabled={busy || replaceConf.trim().length === 0} onclick={replaceTunnel}>
        {replacePhase === 'running' ? 'Применяю…' : 'Заменить конфиг'}
      </button>
    </div>
    {#if replacePhase === 'running'}
      <p><span class="spinner"></span> Применяю новый конфиг — при сбое прежний вернётся автоматически.</p>
    {/if}
    {#if replaceLog && replacePhase !== 'idle'}
      <details open={replacePhase === 'fail'}>
        <summary>Журнал замены</summary>
        <pre class="log">{replaceLog}</pre>
      </details>
    {/if}

    <!-- Full-тир не установлен: либо кнопка догрузки (железо тянет), либо честное объяснение,
         почему её нет. Молчать нельзя — иначе человек не поймёт, почему у него нет функции,
         о которой написано в документации. -->
    {#if !s.full_installed}
      <h3 id="full-tier">Запасные туннели — если этот не выручает</h3>
      {#if s.full_capable}
        <p class="muted small">Кроме основного туннеля есть два запасных, на разные беды:
          <strong>VLESS+Reality</strong> — когда интернет через VPN вообще не открывается (снаружи
          выглядит как обычный HTTPS), и <strong>Hysteria2</strong> — когда открывается, но тормозит
          и рвётся (держит скорость на канале с потерями).</p>
        <p class="muted small">Кнопка догрузит общий для них компонент <code>sing-box</code> — один
          раз, из интернета (~11 МБ скачать, ~30 МБ займёт в памяти роутера).
          <strong>Текущий туннель продолжит работать</strong>: переключиться можно потом, когда
          появится ссылка от сервера, и так же вернуться назад.</p>
        <div class="row">
          <button disabled={busy || fullPhase === 'running'} onclick={enableFullTier}>
            {fullPhase === 'running' ? 'Устанавливаю…' : 'Установить компонент'}
          </button>
        </div>
        {#if fullPhase === 'running'}
          <p><span class="spinner"></span> Скачиваю компонент — это может занять минуту.</p>
        {/if}
        {#if fullLog && fullPhase !== 'idle'}
          <details open={fullPhase === 'fail'}>
            <summary>Журнал установки</summary>
            <pre class="log">{fullLog}</pre>
          </details>
        {/if}
      {:else}
        <p class="muted small">Есть два запасных туннеля — <strong>VLESS+Reality</strong> (когда
          интернет через VPN вообще не открывается) и <strong>Hysteria2</strong> (когда открывается,
          но тормозит и рвётся). <strong>На этом роутере они недоступны</strong>{#if fullMissing}:
          {fullMissing}{/if}. Они считаются не в ядре, а в обычной программе — на слабом железе
          работали бы медленнее самого интернета. {#if s.full_missing?.includes('flash')}Место можно
          освободить (по SSH <code>apk del</code> ненужные пакеты) или подключить USB-флешку
          (extroot) — тогда кнопка появится.{/if}</p>
      {/if}
    {/if}

    <!-- Смена туннеля: один блок на каждый доступный вариант. AmneziaWG доступен всегда,
         Full-протоколы — когда компонент установлен (иначе выше кнопка догрузки). -->
    {#if targets.length > 0}
      <h3>Сменить туннель</h3>
      <p class="muted small">Сейчас активен <strong>{active.name}</strong>. Переключение идёт на
        месте: домены, DNS и режим сохранятся, мастер проходить не нужно. Если новый туннель не
        поднимется, прежний вернётся автоматически.</p>
      {#each targets as p}
        <h4 id="switch-{p.id}">{p.name} — {p.symptom.toLowerCase()}</h4>
        <p class="muted small">{p.why}</p>
        <label>
          <span>{p.confLabel}</span>
          <textarea bind:value={switchConfs[p.id]} rows="4" disabled={busy}
            placeholder={p.placeholder}></textarea>
        </label>
        {#if p.file}
          <label class="file">
            <span>…или загрузить файлом</span>
            <input type="file" accept=".conf,text/plain" onchange={onSwitchFile} disabled={busy} />
          </label>
        {/if}
        <div class="row">
          <button disabled={busy || (switchConfs[p.id] ?? '').trim().length === 0} onclick={() => switchTo(p)}>
            {switchPhase === 'running' && switchTarget === p.id ? 'Переключаю…' : `Переключиться на ${p.name}`}
          </button>
        </div>
      {/each}
      {#if switchPhase === 'running'}
        <p><span class="spinner"></span> Поднимаю {protocolInfo(switchTarget).name} — при сбое
          вернётся {active.name}.</p>
      {/if}
      {#if switchLog && switchPhase !== 'idle'}
        <details open={switchPhase === 'fail'}>
          <summary>Журнал переключения</summary>
          <pre class="log">{switchLog}</pre>
        </details>
      {/if}
    {/if}

    <!-- Скорость канала (Brutal) относится к Hysteria2: и когда он уже активен (замена сервера),
         и когда на него переключаются. Поле не голое: завышенное значение делает связь ХУЖЕ, и
         молча — поэтому дефолт автоматический, а ручной режим с предупреждением. -->
    {#if active.id === 'hysteria2' || targets.some((p) => p.id === 'hysteria2')}
      <h4>Скорость канала (только для Hysteria2)</h4>
      <label class="radio">
        <input type="radio" bind:group={declareSpeed} value={false} disabled={busy} />
        <span><strong>Подбирать автоматически</strong> — рекомендуем.</span>
      </label>
      <label class="radio">
        <input type="radio" bind:group={declareSpeed} value={true} disabled={busy} />
        <span><strong>Указать вручную</strong> — иногда выжимает больше на канале с потерями.</span>
      </label>
      {#if declareSpeed}
        <p class="warn">Указывайте скорость, которую интернет <strong>реально держит</strong>, и
          лучше немного меньше. Если написать больше, чем есть, связь станет <strong>хуже</strong>:
          вырастут задержки и начнутся обрывы — и никакой ошибки при этом не появится.</p>
        <label>
          <span>Скорость приёма (Мбит/с)</span>
          <input type="number" min="1" max="10000" bind:value={speedDown} disabled={busy} />
        </label>
        <label>
          <span>Скорость отдачи (Мбит/с)</span>
          <input type="number" min="1" max="10000" bind:value={speedUp} disabled={busy} />
        </label>
      {/if}
    {/if}

    {#if action}<p class="muted">{action}</p>{/if}

    {#if loggedIn}
      <p class="muted small">Вы вошли как root. <button class="linklike" onclick={doLogout}>Выйти</button></p>
    {:else}
      <p class="muted small">
        Управляющие действия требуют входа.
        <button class="linklike" onclick={() => (loginOpen = true)}>Войти</button>
      </p>
    {/if}

    <h3 class="danger-h">Опасная зона</h3>
    {#if !resetArmed}
      <button class="danger" disabled={busy} onclick={() => (resetArmed = true)}>Сбросить настройку cheburnet…</button>
    {:else}
      <p class="warn">
        Будет снята вся конфигурация cheburnet (туннель, split-routing, шифрованный DNS,
        блок-листы). Роутер вернётся к обычной маршрутизации. Wi-Fi и пароль роутера останутся.
      </p>
      <label>
        <span>Введите слово <code>RESET</code> для подтверждения</span>
        <input type="text" bind:value={resetWord} placeholder="RESET" />
      </label>
      <div class="row">
        <button disabled={busy} onclick={() => { resetArmed = false; resetWord = ''; }}>Отмена</button>
        <button class="danger" disabled={busy || resetWord.trim() !== 'RESET'} onclick={factoryReset}>
          Подтвердить сброс
        </button>
      </div>
    {/if}
  {:else}
    <p class="muted">Загрузка…</p>
  {/if}

  <hr />
  <button onclick={onReinstall}>Настроить заново</button>

  {#if loginOpen}
    <div class="modal-back" role="presentation" onclick={() => (loginOpen = false)}>
      <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
      <div class="modal" onclick={(e) => e.stopPropagation()}>
        <h3>Вход в управление</h3>
        <p class="muted small">Пароль администратора роутера (root) — тот, что задан при установке.</p>
        <label>
          <span>Пароль</span>
          <input
            type="password"
            bind:value={loginPass}
            autocomplete="current-password"
            disabled={loginAttempts >= MAX_LOGIN_ATTEMPTS}
            onkeydown={(e) => e.key === 'Enter' && doLogin()}
          />
        </label>
        {#if loginError}<p class="warn">{loginError}</p>{/if}
        <div class="row">
          <button onclick={() => (loginOpen = false)}>Отмена</button>
          <button
            class="primary"
            disabled={loginPass.length === 0 || loginAttempts >= MAX_LOGIN_ATTEMPTS}
            onclick={doLogin}
          >Войти</button>
        </div>
      </div>
    </div>
  {/if}
</section>
