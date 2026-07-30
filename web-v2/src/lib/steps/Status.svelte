<script>
  import { onDestroy } from 'svelte';
  import { cheburnet, login, isLoggedIn, logout } from '../ubus.js';
  import { hs, FORCED_LABELS, heroKind, realityFallback, tunnelRowText,
           explainFullTierFail, fullMissingText } from '../logic.js';

  // onReinstall — запустить мастер заново (с preflight).
  let { onReinstall } = $props();

  let s = $state(null);
  let error = $state('');
  let action = $state(''); // текст результата/ошибки управляющего действия
  let busy = $state(false);
  let awgConf = $state('');
  let realityConf = $state(''); // vless://… или JSON sing-box (Full-тир)
  let awgPhase = $state('idle'); // idle | running | ok | fail
  let awgLog = $state('');
  let resetWord = $state('');
  let resetArmed = $state(false);
  let fullPhase = $state('idle'); // Full-тир (sing-box): idle | running | ok | fail
  let fullLog = $state('');
  let switchConf = $state('');    // vless:// для in-place переключения AWG→Reality
  let switchAwgConf = $state(''); // AWG .conf для обратного переключения Reality→AWG
  let switchTarget = $state('reality'); // направление текущего свитча: 'reality' | 'awg'
  let switchPhase = $state('idle');
  let switchLog = $state('');
  let timer = null;
  let awgTimer = null;
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
  // ЧЕМ мерить каждый протокол; fallback — что предлагать, если AmneziaWG не поднимается.
  const hero = $derived(heroKind(s));
  const fallback = $derived(realityFallback(s));
  // Чего не хватает железу для Full-тира (status.full_missing) — человеческими словами.
  const fullMissing = $derived(fullMissingText(s?.full_missing));
  const setProvider = () =>
    admin(`DNS-провайдер: ${providerSel}`, () => cheburnet('set_dns_provider', { provider: providerSel }));

  // Замена AWG-конфига: метод стартует фон (snapshot → apply → handshake → commit/rollback),
  // прогресс поллим через install_progress — тот же канал, что у установки.
  async function onAwgFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    awgConf = await f.text();
  }

  // Замена туннель-конфига. Метод и поле зависят от активного протокола: reality (Full) →
  // replace_reality_conf, awg (Light) → replace_awg_conf. Оба идут одним фон+poll-каналом
  // (install_progress), поэтому прогресс-состояние awg* переиспользуется.
  async function replaceTunnel() {
    const reality = s?.protocol === 'reality';
    const conf = reality ? realityConf : awgConf;
    if (conf.trim().length === 0) {
      action = reality ? 'Вставьте новую ссылку vless:// или конфиг.' : 'Вставьте или загрузите новый AWG-конфиг.';
      return;
    }
    busy = true;
    action = '';
    awgLog = '';
    try {
      if (reality)
        await cheburnet('replace_reality_conf', { reality_conf: conf });
      else
        await cheburnet('replace_awg_conf', { awg_conf: conf });
      awgPhase = 'running';
      awgTimer = setInterval(pollAwg, 2000);
    } catch (e) {
      action = `Замена конфига: ${e.message} (управление требует входа).`;
      busy = false;
    }
  }

  async function pollAwg() {
    try {
      const p = await cheburnet('install_progress');
      awgLog = p.log ?? '';
      if (p.done) {
        clearInterval(awgTimer);
        awgTimer = null;
        busy = false;
        const reality = s?.protocol === 'reality';
        if (p.result === 'ok') {
          awgPhase = 'ok';
          awgConf = '';
          realityConf = '';
          action = reality
            ? 'Новый Reality-сервер применён (трафик идёт через туннель).'
            : 'Новый AWG-конфиг применён (handshake получен).';
        } else {
          awgPhase = 'fail';
          // Честный намёк на случай, когда виноват не сервер, а сеть — иначе пользователь меняет
          // один конфиг на другой по кругу без понимания, почему все падают.
          action = reality
            ? 'Новый сервер тоже не отозвался — прежний возвращён автоматически. Проверьте, что '
              + 'ссылка vless:// свежая и сервер жив; если несколько серверов подряд не работают, '
              + 'возможно, сеть блокирует и его.'
            : 'Новый конфиг тоже не поднялся — прежний возвращён автоматически. '
              + 'Если несколько свежих конфигов подряд не работают, возможно, ваша сеть блокирует '
              + 'этот тип VPN (AmneziaWG работает по UDP) — попробуйте конфиг другого сервера или '
              + 'другую сеть/провайдера.';
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
    if (awgTimer) clearInterval(awgTimer);
    if (fullTimer) clearInterval(fullTimer);
    if (switchTimer) clearInterval(switchTimer);
  });

  // In-place переключение AWG→Reality: приносим только ссылку, домены/DNS берутся из сохранённого
  // конфига (мастер не проходим). run.uc делает snapshot→teardown awg0→apply→probe→commit/rollback,
  // прогресс — тот же канал install_progress. При сбое AWG возвращается автоматически.
  async function switchToReality() {
    if (switchConf.trim().length === 0) {
      action = 'Вставьте ссылку vless:// от вашего Reality-сервера.';
      return;
    }
    switchTarget = 'reality';
    busy = true; action = ''; switchLog = '';
    try {
      await cheburnet('switch_to_reality', { reality_conf: switchConf });
      switchPhase = 'running';
      switchTimer = setInterval(pollSwitch, 2000);
    } catch (e) {
      busy = false;
      if (e.message.includes('PERMISSION_DENIED')) {
        logout(); loggedIn = false; loginOpen = true;
        action = 'Переключение: нужен вход — введите пароль роутера.';
      } else {
        action = `Переключение: ${e.message}`;
      }
    }
  }

  // Обратное in-place переключение Reality→AmneziaWG (зеркало switchToReality): приносим только
  // AWG-конфиг, домены/DNS берутся из сохранённого. sing-box остаётся установленным — назад на
  // Reality можно вернуться сразу. При сбое Reality возвращается автоматически. Тот же фон+poll.
  async function switchToAwg() {
    if (switchAwgConf.trim().length === 0) {
      action = 'Вставьте или загрузите AWG-конфиг.';
      return;
    }
    switchTarget = 'awg';
    busy = true; action = ''; switchLog = '';
    try {
      await cheburnet('switch_to_awg', { awg_conf: switchAwgConf });
      switchPhase = 'running';
      switchTimer = setInterval(pollSwitch, 2000);
    } catch (e) {
      busy = false;
      if (e.message.includes('PERMISSION_DENIED')) {
        logout(); loggedIn = false; loginOpen = true;
        action = 'Переключение: нужен вход — введите пароль роутера.';
      } else {
        action = `Переключение: ${e.message}`;
      }
    }
  }

  async function onSwitchAwgFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    switchAwgConf = await f.text();
  }

  async function pollSwitch() {
    try {
      const p = await cheburnet('install_progress');
      switchLog = p.log ?? '';
      if (p.done) {
        clearInterval(switchTimer); switchTimer = null; busy = false;
        if (p.result === 'ok') {
          switchPhase = 'ok';
          switchConf = ''; switchAwgConf = '';
          action = switchTarget === 'awg'
            ? 'Переключено на AmneziaWG — туннель работает.'
            : 'Переключено на VLESS+Reality — туннель работает.';
        } else {
          switchPhase = 'fail';
          action = switchTarget === 'awg'
            ? 'Не удалось поднять AmneziaWG — прежний туннель (VLESS+Reality) возвращён автоматически. Проверьте, что AWG-конфиг вставлен целиком и сервер жив.'
            : 'Не удалось поднять VLESS+Reality — прежний туннель (AmneziaWG) возвращён автоматически. Проверьте ссылку и что сервер жив.';
        }
        await refresh();
      }
    } catch { /* единичный сбой поллинга — следующий тик повторит */ }
  }

  // Full-тир (opt-in): кнопка догружает sing-box (apk add sing-box) фоном. Прогресс — тот же
  // канал install_progress. AmneziaWG при этом не трогается (ставим только пакет).
  async function enableFullTier() {
    busy = true; action = ''; fullLog = '';
    try {
      await cheburnet('install_full_tier');
      fullPhase = 'running';
      fullTimer = setInterval(pollFull, 2000);
    } catch (e) {
      busy = false;
      if (e.message.includes('PERMISSION_DENIED')) {
        logout(); loggedIn = false; loginOpen = true;
        action = 'Установка VLESS+Reality: нужен вход — введите пароль роутера.';
      } else {
        action = `Установка VLESS+Reality: ${e.message}`;
      }
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
          action = 'sing-box установлен. Ниже появился блок «Переключиться на VLESS+Reality» — вставьте туда ссылку vless:// от вашего сервера.';
        } else {
          fullPhase = 'fail';
          // Причина из движка (install-singbox.sh пишет REASON_FILE): совет «проверьте интернет»
          // на забитом флеше отправлял чинить не то, а sing-box (~15 МБ) реально может не влезть.
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
    {#if hero === 'awg-down'}
      <p class="banner">
        <strong>⚠️ VPN не работает.</strong> Сайты, которые идут через VPN, сейчас недоступны —
        открываются только сайты из списка «напрямую». Обычная причина: сервер вашего
        VPN-провайдера отключён или заблокирован. Что делать: попробуйте кнопку
        «Туннель» в «Перезапуск сервисов»; не помогло — <a href="#replace-awg">загрузите свежий
        конфиг</a> от провайдера (или другого сервера/локации).
      </p>
      <!-- Главный сценарий Full-тира: конфиг свежий, сервер жив, а туннель не встаёт — значит
           сеть, скорее всего, режет сам протокол (AmneziaWG работает по UDP). Ведём к запасному
           пути ровно в тот момент, когда он нужен, а не прячем его в конце страницы. -->
      {#if fallback === 'install'}
        <p class="note">
          Загрузили свежий конфиг, а туннель всё равно не поднимается? Бывает, что сеть режет сам
          протокол AmneziaWG — он работает по UDP. Тогда помогает запасной путь:
          <a href="#full-tier">добавить VLESS+Reality</a> — он маскируется под обычный HTTPS.
          Ставится один раз, AmneziaWG никуда не денется.
        </p>
      {:else if fallback === 'switch'}
        <p class="note">
          Загрузили свежий конфиг, а туннель всё равно не поднимается? Возможно, сеть режет протокол
          AmneziaWG (он работает по UDP). Компонент <code>sing-box</code> у вас уже установлен —
          <a href="#switch-reality">переключитесь на VLESS+Reality</a> (нужна ссылка
          <code>vless://</code> от вашего сервера). Вернуться назад можно в один шаг.
        </p>
      {/if}
    {:else if hero === 'reality-down'}
      <p class="banner">
        <strong>⚠️ Туннель VLESS+Reality не поднят.</strong> Сайты, которые идут через VPN, сейчас
        недоступны — открываются только сайты из списка «напрямую». Что делать: попробуйте кнопку
        «Туннель» в «Перезапуск сервисов»; не помогло — возьмите
        <a href="#replace-reality">свежую ссылку <code>vless://</code></a> от своего сервера, либо
        <a href="#switch-awg">вернитесь на AmneziaWG</a>.
      </p>
    {:else if hero === 'reality-up'}
      <!-- Формулировка слабее, чем у AWG, ОСОЗНАННО: у Reality нет рукопожатия — мы видим, что
           туннель поднят, но не что сервер отвечает. Не обещаем «всё работает», а даём проверку. -->
      <p class="ok-msg">✅ VLESS+Reality активен: трафик идёт через туннель.</p>
      <p class="muted small">Если сайты всё же не открываются — сервер мог отключиться. Свежая
        ссылка <code>vless://</code> вставляется ниже, прежняя вернётся сама при неудаче.</p>
    {:else if hero === 'awg-up'}
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
      <!-- Подпись зависит от протокола: у AWG видно, когда сервер отвечал; у Reality — только
           что туннель поднят (см. tunnelRowText). Цвет — из единого tunnel_health движка. -->
      <li class:ok={s.tunnel_health === 'up'} class:bad={s.tunnel_health !== 'up'}>
        <span>{s.protocol === 'reality' ? 'Туннель (VLESS+Reality)' : 'VPN-сервер'}</span>
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

    <!-- Full-тир (VLESS+Reality) — opt-in. Показываем только на подходящем железе (full_capable).
         Не установлен → кнопка догрузки sing-box. Установлен, но активен AWG → подсказка переключиться. -->
    {#if s.full_capable && !s.full_installed}
      <h3 id="full-tier">VLESS + Reality — запасной туннель</h3>
      <p class="muted small">Основной туннель — <strong>AmneziaWG</strong>: лёгкий, быстрый, работает
        в ядре роутера. Если он не поднимается (бывает, что сеть режет UDP-протоколы), есть запасной
        путь — <strong>VLESS+Reality</strong>: он маскируется под обычный HTTPS, поэтому проходит там,
        где UDP-туннель не проходит. Цена — тяжелее для роутера: туннель считается в обычных
        программах, а не в ядре.</p>
      <p class="muted small">Кнопка догрузит компонент <code>sing-box</code> — один раз, из интернета
        (~15 МБ скачать, ~42 МБ займёт в памяти роутера). <strong>AmneziaWG продолжит работать</strong>: переключиться можно потом, когда
        появится ссылка от Reality-сервера, и так же вернуться назад.</p>
      <div class="row">
        <button disabled={busy || fullPhase === 'running'} onclick={enableFullTier}>
          {fullPhase === 'running' ? 'Устанавливаю…' : 'Включить VLESS+Reality'}
        </button>
      </div>
      {#if fullPhase === 'running'}
        <p><span class="spinner"></span> Скачиваю sing-box — это может занять минуту.</p>
      {/if}
      {#if fullLog && fullPhase !== 'idle'}
        <details open={fullPhase === 'fail'}>
          <summary>Журнал установки</summary>
          <pre class="log">{fullLog}</pre>
        </details>
      {/if}
    {:else if s.full_installed && s.protocol !== 'reality'}
      <h3 id="switch-reality">Переключиться на VLESS+Reality</h3>
      <p class="muted small">Компонент <code>sing-box</code> установлен, сейчас активен AmneziaWG.
        Вставьте ссылку <code>vless://</code> от вашего Reality-сервера — переключим туннель на месте
        (домены и DNS сохранятся, мастер проходить не нужно). Если новый туннель не поднимется,
        AmneziaWG вернётся автоматически.</p>
      <label>
        <span>Ссылка vless:// или конфиг sing-box</span>
        <textarea bind:value={switchConf} rows="5" disabled={busy}
          placeholder="vless://uuid@host:443?security=reality&pbk=…&sni=…&#10;…или JSON-конфиг sing-box"></textarea>
      </label>
      <div class="row">
        <button disabled={busy || switchConf.trim().length === 0} onclick={switchToReality}>
          {switchPhase === 'running' ? 'Переключаю…' : 'Переключиться на VLESS+Reality'}
        </button>
      </div>
      {#if switchPhase === 'running'}
        <p><span class="spinner"></span> Поднимаю VLESS+Reality — при сбое вернётся AmneziaWG.</p>
      {/if}
      {#if switchLog && switchPhase !== 'idle'}
        <details open={switchPhase === 'fail'}>
          <summary>Журнал переключения</summary>
          <pre class="log">{switchLog}</pre>
        </details>
      {/if}
    {:else if !s.full_capable && !s.full_installed}
      <!-- Слабое железо: молчать нельзя — человек иначе не поймёт, почему у него нет кнопки, о
           которой написано в документации. Говорим честно, что именно нужно. -->
      <h3>VLESS + Reality — запасной туннель</h3>
      <p class="muted small">Если основной туннель (AmneziaWG) не поднимается из-за того, что сеть
        режет UDP, обычно помогает <strong>VLESS+Reality</strong> — он маскируется под обычный HTTPS.
        <strong>На этом роутере он недоступен</strong>{#if fullMissing}: {fullMissing}{/if}. Такой
        туннель считается не в ядре, а в обычной программе — на слабом железе он работал бы
        медленнее самого интернета. {#if s.full_missing?.includes('flash')}Место можно освободить
        (по SSH <code>apk del</code> ненужные пакеты) или подключить USB-флешку (extroot) — тогда
        кнопка появится.{/if}</p>
    {/if}

    {#if s.protocol === 'reality'}
      <h3 id="replace-reality">Замена Reality-сервера</h3>
      <p class="muted small">Если туннель перестал работать — возьмите свежую ссылку
        <code>vless://…</code> из панели вашего Reality-сервера (3x-ui / Hiddify) и вставьте здесь.
        Если новый сервер не отзовётся, прежний вернётся автоматически — сломать нельзя.</p>
      <label>
        <span>Новая ссылка vless:// или конфиг</span>
        <textarea bind:value={realityConf} rows="5" disabled={busy}
          placeholder="vless://uuid@host:443?security=reality&pbk=…&sni=…&#10;…или JSON-конфиг sing-box"></textarea>
      </label>
    {:else}
      <h3 id="replace-awg">Замена VPN-конфига</h3>
      <p class="muted small">Если VPN перестал работать — возьмите свежий <code>.conf</code> у вашего
        VPN-провайдера (или другого сервера/локации) и загрузите здесь. Если новый конфиг не
        поднимется, прежний вернётся автоматически — сломать нельзя.</p>
      <label>
        <span>Новый AWG-конфиг</span>
        <textarea bind:value={awgConf} rows="5" disabled={busy}
          placeholder="[Interface]&#10;PrivateKey = …&#10;[Peer]&#10;…"></textarea>
      </label>
      <label class="file">
        <span>…или загрузить файлом</span>
        <input type="file" accept=".conf,text/plain" onchange={onAwgFile} disabled={busy} />
      </label>
    {/if}
    <div class="row">
      <button disabled={busy || (s.protocol === 'reality' ? realityConf : awgConf).trim().length === 0} onclick={replaceTunnel}>
        {awgPhase === 'running' ? 'Применяю…' : 'Заменить конфиг'}
      </button>
    </div>
    {#if awgPhase === 'running'}
      <p><span class="spinner"></span> Применяю новый конфиг — при сбое прежний вернётся автоматически.</p>
    {/if}
    {#if awgLog && awgPhase !== 'idle'}
      <details open={awgPhase === 'fail'}>
        <summary>Журнал замены</summary>
        <pre class="log">{awgLog}</pre>
      </details>
    {/if}

    <!-- Обратное переключение на AmneziaWG (только когда активен Reality). sing-box остаётся
         установленным, поэтому назад на Reality можно вернуться в один шаг через блок выше. -->
    {#if s.protocol === 'reality'}
      <h3 id="switch-awg">Вернуться на AmneziaWG</h3>
      <p class="muted small">Сейчас активен <strong>VLESS+Reality</strong>. Если хотите вернуться на
        лёгкий и быстрый <code>AmneziaWG</code> — вставьте его <code>.conf</code> и переключим туннель
        на месте (домены и DNS сохранятся). Если AmneziaWG не поднимется, VLESS+Reality вернётся
        автоматически. Компонент <code>sing-box</code> при этом останется — назад можно в один шаг.</p>
      <label>
        <span>AWG-конфиг (файл <code>.conf</code>)</span>
        <textarea bind:value={switchAwgConf} rows="5" disabled={busy}
          placeholder="[Interface]&#10;PrivateKey = …&#10;[Peer]&#10;…"></textarea>
      </label>
      <label class="file">
        <span>…или загрузить файлом</span>
        <input type="file" accept=".conf,text/plain" onchange={onSwitchAwgFile} disabled={busy} />
      </label>
      <div class="row">
        <button disabled={busy || switchAwgConf.trim().length === 0} onclick={switchToAwg}>
          {switchPhase === 'running' && switchTarget === 'awg' ? 'Переключаю…' : 'Вернуться на AmneziaWG'}
        </button>
      </div>
      {#if switchPhase === 'running' && switchTarget === 'awg'}
        <p><span class="spinner"></span> Поднимаю AmneziaWG — при сбое вернётся VLESS+Reality.</p>
      {/if}
      {#if switchLog && switchPhase !== 'idle' && switchTarget === 'awg'}
        <details open={switchPhase === 'fail'}>
          <summary>Журнал переключения</summary>
          <pre class="log">{switchLog}</pre>
        </details>
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
