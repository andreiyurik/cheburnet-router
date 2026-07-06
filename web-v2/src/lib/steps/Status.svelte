<script>
  import { onDestroy } from 'svelte';
  import { cheburnet, login, isLoggedIn, logout } from '../ubus.js';

  // onReinstall — запустить мастер заново (с preflight).
  let { onReinstall } = $props();

  let s = $state(null);
  let error = $state('');
  let action = $state(''); // текст результата/ошибки управляющего действия
  let busy = $state(false);
  let awgConf = $state('');
  let awgPhase = $state('idle'); // idle | running | ok | fail
  let awgLog = $state('');
  let resetWord = $state('');
  let resetArmed = $state(false);
  let timer = null;
  let awgTimer = null;

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
        ? 'Попытки исчерпаны. Перезагрузите страницу или войдите по SSH и проверьте пароль.'
        : `${e.message} (попытка ${loginAttempts} из ${MAX_LOGIN_ATTEMPTS})`;
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
  const setProvider = () =>
    admin(`DNS-провайдер: ${providerSel}`, () => cheburnet('set_dns_provider', { provider: providerSel }));

  // Замена AWG-конфига: метод стартует фон (snapshot → apply → handshake → commit/rollback),
  // прогресс поллим через install_progress — тот же канал, что у установки.
  async function onAwgFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    awgConf = await f.text();
  }

  async function replaceAwg() {
    if (awgConf.trim().length === 0) {
      action = 'Вставьте или загрузите новый AWG-конфиг.';
      return;
    }
    busy = true;
    action = '';
    awgLog = '';
    try {
      await cheburnet('replace_awg_conf', { awg_conf: awgConf });
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
        if (p.result === 'ok') {
          awgPhase = 'ok';
          awgConf = '';
          action = 'Новый AWG-конфиг применён (handshake получен).';
        } else {
          awgPhase = 'fail';
          action = 'Новый конфиг не заработал — прежний возвращён автоматически.';
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

  function hs(age) {
    if (age == null) return 'нет рукопожатия';
    if (age < 0) return '—';
    if (age < 120) return `${age} с назад`;
    return `${Math.floor(age / 60)} мин назад`;
  }

  refresh();
  // 15 с, не чаще: каждый опрос — это спавн rpcd-скрипта + shell-батч на роутере (слабое железо).
  timer = setInterval(refresh, 15000);
  onDestroy(() => {
    if (timer) clearInterval(timer);
    if (awgTimer) clearInterval(awgTimer);
  });
</script>

<section>
  <h2>Состояние</h2>

  {#if error}<p class="warn">{error}</p>{/if}

  {#if s}
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

    <ul class="status">
      <li><span>Режим</span><strong>{s.mode === 'travel' ? 'TRAVEL (всё в туннель)' : 'HOME (split)'}</strong></li>
      <li><span>Домены прямого доступа</span><strong>{s.direct_domains}</strong></li>
      <li><span>Импортированный список</span><strong>{s.direct_list_loaded ? `${s.imported_domains} доменов` : 'не загружен'}</strong></li>
      <li><span>Туннель (handshake)</span><strong>{hs(s.awg_handshake_age)}</strong></li>
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
        {s.mode === 'travel' ? 'Включить HOME' : 'Включить TRAVEL'}
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

    <h3>Замена VPN-конфига</h3>
    <label>
      <span>Новый AWG-конфиг</span>
      <textarea bind:value={awgConf} rows="5" disabled={busy}
        placeholder="[Interface]&#10;PrivateKey = …&#10;[Peer]&#10;…"></textarea>
    </label>
    <label class="file">
      <span>…или загрузить файлом</span>
      <input type="file" accept=".conf,text/plain" onchange={onAwgFile} disabled={busy} />
    </label>
    <div class="row">
      <button disabled={busy || awgConf.trim().length === 0} onclick={replaceAwg}>
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
