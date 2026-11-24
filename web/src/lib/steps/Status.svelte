<script>
  import { onDestroy } from 'svelte';
  import { cheburnet, login, isLoggedIn, logout, isAccessDenied } from '../ubus.js';
  import { hs, FORCED_LABELS, heroKind, tunnelFallback, switchTargets, tunnelRowText,
           protocolInfo, checkConf,
           SUPPORT, parseDomains } from '../logic.js';
  import * as Alert from '$lib/components/ui/alert/index.js';
  import Button from '$lib/components/ui/button/button.svelte';
  import Input from '$lib/components/ui/input/input.svelte';
  import Textarea from '$lib/components/ui/textarea/textarea.svelte';
  import NativeSelect from '$lib/components/ui/native-select/native-select.svelte';
  import RadioCard from '$lib/components/ui/radio-card/radio-card.svelte';
  import Modal from '$lib/components/ui/modal/modal.svelte';
  import Spinner from '$lib/components/ui/spinner/spinner.svelte';
  import Field from '$lib/components/Field.svelte';
  import SectionTitle from '$lib/components/SectionTitle.svelte';
  import DetailsGroup from '$lib/components/DetailsGroup.svelte';
  import LogView from '$lib/components/LogView.svelte';
  import StatusIcon from '$lib/components/StatusIcon.svelte';
  import StatusList from '$lib/components/StatusList.svelte';
  import StatusRow from '$lib/components/StatusRow.svelte';
  import ConfCheck from '$lib/components/ConfCheck.svelte';
  import Servers from '$lib/components/Servers.svelte';
  import FileButton from '$lib/components/FileButton.svelte';
  import * as Card from '$lib/components/ui/card/index.js';
  import * as Item from '$lib/components/ui/item/index.js';
  import * as F from '$lib/components/ui/field/index.js';
  import { ButtonGroup } from '$lib/components/ui/button-group/index.js';
  import Badge from '$lib/components/ui/badge/badge.svelte';
  import { Kbd } from '$lib/components/ui/kbd/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';
  import ShieldCheck from '@lucide/svelte/icons/shield-check';
  import ShieldAlert from '@lucide/svelte/icons/shield-alert';
  import ShieldOff from '@lucide/svelte/icons/shield-off';
  import House from '@lucide/svelte/icons/house';
  import Plane from '@lucide/svelte/icons/plane';
  import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
  import Globe from '@lucide/svelte/icons/globe';
  import KeyRound from '@lucide/svelte/icons/key-round';
  import LifeBuoy from '@lucide/svelte/icons/life-buoy';
  import Stethoscope from '@lucide/svelte/icons/stethoscope';
  import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
  import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
  import LogIn from '@lucide/svelte/icons/log-in';
  import LogOut from '@lucide/svelte/icons/log-out';
  import Heart from '@lucide/svelte/icons/heart';

  // onReinstall — запустить мастер заново (с preflight).
  let { onReinstall } = $props();

  let s = $state(null);
  let error = $state('');
  // Панель делает восемь разных вещей; развёрнуто по умолчанию только то, ради чего сюда заходят
  // («работает ли?» и перезапуск). Остальное — свёрнуто, но открывается само, когда hero ведёт
  // в блок ссылкой: иначе якорь прыгал бы в закрытый <details>.
  let tunnelOpen = $state(false);
  // Сервисы и фильтрация свёрнуты: перезапуск нужен в редкий день поломки, провайдер DNS
  // выбирают один раз. Ссылка из hero-баннера раскрывает группу сама (как у туннеля).
  let servicesOpen = $state(false);
  let dangerOpen = $state(false);
  let serversOpen = $state(false);
  // Отказ доступа из блока серверов: протухшую сессию выбрасываем и открываем вход (как в admin()).
  function serversDenied() {
    if (loggedIn) { logout(); loggedIn = false; }
    loginOpen = true;
  }
  let action = $state(''); // текст результата/ошибки управляющего действия
  // Где показать это сообщение. Одно место на всю страницу означало, что результат нажатия
  // верхней кнопки появлялся через два экрана вниз — человек его просто не видел. Каждое
  // сообщение печатается у той группы кнопок, которая его вызвала.
  let actionScope = $state('manage'); // manage | restart | dns | replace | switch | full | danger
  let busy = $state(false);
  // Подряд неудачные опросы фоновой операции = страница потеряла роутер (сменился адрес, ребут
  // посреди операции). Раньше catch глотал всё: «Применяю…» висело до F5 при заблокированной
  // панели. Тот же порог, что у мастера (Installing.svelte).
  let pollFails = $state(0);
  function pollLost(scope) {
    pollFails++;
    if (pollFails !== 4) return;
    busy = false;
    actionScope = scope;
    action = 'Страница потеряла связь с роутером — операция продолжается на нём самом. '
      + 'Обновите страницу через минуту; если менялся адрес роутера — откройте новый.';
  }
  // Замена сервера АКТИВНОГО туннеля: одно поле, метод и подпись — из каталога протоколов.
  let replaceConf = $state('');
  let replacePhase = $state('idle'); // idle | running | ok | fail
  let replaceLog = $state('');
  let resetWord = $state('');
  let resetArmed = $state(false);
  // Смена туннеля: конфиги хранятся ПО ПРОТОКОЛАМ (переключение выбора не теряет вставленное).
  let switchConfs = $state({ awg: '' });
  // switchPick — ВЫБРАННОЕ направление (радио), switchTarget — то, что уже переключается.
  // Раньше блоков было по одному на протокол: три похожих поля для ссылок на одной странице, и
  // вставить в чужое — обычное дело. Теперь как в мастере: сначала выбор по симптому, потом одно поле.
  let switchPick = $state('');
  let switchTarget = $state('');  // направление текущего свитча
  let switchPhase = $state('idle');
  let switchLog = $state('');
  let timer = null;
  let replaceTimer = null;
  let switchTimer = null;

  // Вход (admin-сессия root).
  let loggedIn = $state(isLoggedIn());
  let loginOpen = $state(false);
  let loginPass = $state('');
  let loginError = $state('');
  let loginAttempts = $state(0);
  let loginInput = $state(null);
  // Квирк браузеров: атрибут autofocus не срабатывает на узле, вставленном ПОСЛЕ загрузки
  // страницы, — модалку открывает клик, поэтому фокус ставим сами (закреплено e2e).
  $effect(() => { if (loginOpen) loginInput?.focus(); });

  async function refresh() {
    try {
      s = await cheburnet('status');
      if (!providerSel && s.dns_provider) providerSel = s.dns_provider;
      error = '';
    } catch (e) {
      error = e.message;
    }
  }

  // Управляющие действия — admin-методы. Без сессии (или с протухшей) — отказ доступа
  // (isAccessDenied, ubus.js) — открываем модалку входа, а не показываем голую ошибку.
  async function admin(label, fn, scope = 'manage') {
    busy = true;
    action = '';
    actionScope = scope;
    try {
      await fn();
      // Само действие могло сообщить конкретику («Список обновлён: N доменов») — не затираем её
      // безликим «готово». Раньше затирало, и счётчик доменов, который для этого и считался,
      // до экрана не доезжал.
      if (action === '') action = `${label} — готово.`;
      await refresh();
    } catch (e) {
      if (isAccessDenied(e)) {
        logout(); // протухшую сессию (или её отсутствие) выбрасываем
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

  // needLogin(e, what) — общая обработка отказа доступа (isAccessDenied — обе его формы, см.
  // ubus.js) для фоновых операций (они не идут через admin(), потому что там свой поллинг
  // прогресса).
  function needLogin(e, what, scope = 'manage') {
    busy = false;
    actionScope = scope;
    if (isAccessDenied(e)) {
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
      actionScope = 'manage';
      action = 'Вход выполнен — повторите действие.';
      loadDomains();
    } catch (e) {
      loginAttempts += 1;
      loginPass = '';
      // Попытки считаем и показываем, но НЕ блокируем поле: опечатка не должна стоить перезагрузки
      // страницы. Защита от перебора здесь всё равно не наша — пароль проверяет rpcd.
      loginError = `Пароль не подошёл (попытка ${loginAttempts}). Нужен пароль роутера, заданный при установке.`;
    }
  }

  function doLogout() {
    logout();
    loggedIn = false;
    actionScope = 'manage';
    action = 'Вы вышли — управление снова требует входа.';
  }

  const setMode = (mode) => admin(`Режим ${mode}`, () => cheburnet('set_mode', { mode }));

  // Свой список сайтов напрямую — правится здесь, без мастера и переустановки (set_domains
  // переприменяет только DNS-шаг). Список читается после входа: он говорит о привычках дома,
  // поэтому движок отдаёт его только admin-сессии.
  let userDomainsText = $state('');
  let domainsLoaded = $state(false);
  async function loadDomains() {
    try {
      const r = await cheburnet('get_domains');
      userDomainsText = (r.user_domains ?? []).join('\n');
      domainsLoaded = true;
    } catch { /* не вошли или роутер не настроен — поле покажет подсказку */ }
  }
  const saveDomains = () =>
    admin('Список сайтов', async () => {
      const r = await cheburnet('set_domains', { domains: parseDomains(userDomainsText) });
      const rej = r.rejected ?? [];
      action = `Сохранено: своих сайтов ${r.user_domains}, напрямую всего ${r.direct_domains}.`
        + (rej.length ? ` Не похожи на домены и пропущены: ${rej.join(', ')}.` : '');
      await loadDomains();
    });
  const updateList = () =>
    admin('Обновление списка', async () => {
      const r = await cheburnet('update_list');
      action = `Список обновлён: ${r.direct_domains} доменов.`;
    });
  const restart = (service, label) =>
    admin(`Перезапуск: ${label}`, () => cheburnet('service_restart', { service }), 'restart');

  // Аварийный режим: последнее средство, когда туннель не поднять, а интернет нужен сейчас.
  // Подтверждение обязательно — человек выключает защиту, и он должен это осознать.
  const pauseProtection = () => {
    if (!confirm('Выключить защиту и пустить интернет напрямую?\n\n'
      + 'Сайты откроются сразу, но трафик перестанет идти через VPN, а kill-switch будет снят.\n'
      + 'Настройки сохранятся — вернуть защиту можно одной кнопкой.')) return;
    return admin('Аварийный режим', () => cheburnet('pause_protection'), 'emergency');
  };
  const resumeProtection = () =>
    admin('Возврат защиты', () => cheburnet('resume_protection'), 'emergency');
  // DNS-провайдер = уровень фильтрации (реклама/семейный/без). Выбор из каталога (status.dns_providers).
  let providerSel = $state('');

  // Главный сигнал панели и запасной путь — чистые функции (logic.js, под vitest). hero знает,
  // ЧЕМ мерить каждый протокол; fallback — куда вести, если активный туннель не поднимается.
  const hero = $derived(heroKind(s));
  const active = $derived(protocolInfo(s?.protocol));
  const fallback = $derived(tunnelFallback(s));
  const targets = $derived(switchTargets(s));
  // Выбранное направление смены туннеля. Эффект, а не $derived: значение принадлежит радио
  // (пользователь его меняет), а список вариантов приходит асинхронно и меняется после каждого
  // переключения — активный протокол из targets уходит. Досеиваем на первый доступный, чтобы поле
  // ссылки и кнопка никогда не остались без протокола.
  $effect(() => {
    if (targets.length > 0 && !targets.some((p) => p.id === switchPick)) switchPick = targets[0].id;
  });
  const pick = $derived(protocolInfo(switchPick));
  const setProvider = () =>
    admin(`DNS-провайдер: ${providerSel}`, () => cheburnet('set_dns_provider', { provider: providerSel }), 'dns');

  // Загрузка .conf файлом (только у AmneziaWG — ссылку файлом не приносят).
  async function onReplaceFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    replaceConf = await f.text();
  }
  async function onSwitchFile(e, id) {
    const f = e.target.files?.[0];
    if (!f) return;
    switchConfs[id] = await f.text();
  }

  // Диагностика для поддержки: пакет собирает роутер (логи + состояние + версии) с ВЫРЕЗАННЫМИ
  // секретами. Показываем его на экране ДО скачивания — обещание «мы всё вычистили» человек может
  // проверить только глазами, и это единственный честный способ его дать.
  let diagText = $state('');
  let diagRemoved = $state([]);
  let diagPhase = $state('idle'); // idle | running | ok | fail
  async function collectDiagnostics() {
    diagPhase = 'running';
    actionScope = 'support';
    action = '';
    try {
      const r = await cheburnet('diagnostics');
      diagText = r.text ?? '';
      diagRemoved = r.removed ?? [];
      diagPhase = 'ok';
    } catch (e) {
      diagPhase = 'fail';
      needLogin(e, 'Сбор диагностики', 'support');
    }
  }
  // Скачивание через Blob: работает по http без сервера-помощника (панель отдаётся с роутера).
  function downloadDiagnostics() {
    const blob = new Blob([diagText], { type: 'text/plain' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'cheburnet-диагностика.txt';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  // Замена сервера активного туннеля: метод и имя аргумента — из каталога протоколов, поэтому
  // третий протокол не потребовал третьей копии этой функции. Фон+poll — общий канал
  // install_progress (тот же, что у установки).
  async function replaceTunnel() {
    const conf = replaceConf.trim();
    actionScope = 'replace';
    // Формат сверяем ДО вызова: замена — фоновая операция со снимком и откатом, и ссылка,
    // вставленная вместо .conf, стоила бы человеку полного цикла ожидания.
    const bad = checkConf(active.id, conf);
    if (bad) {
      action = bad;
      return;
    }
    busy = true;
    action = '';
    replaceLog = '';
    try {
      await cheburnet(active.replaceMethod, { [active.confKey]: conf });
      replacePhase = 'running';
      replaceTimer = setInterval(pollReplace, 2000);
    } catch (e) {
      needLogin(e, 'Замена конфига', 'replace');
    }
  }

  async function pollReplace() {
    try {
      const p = await cheburnet('install_progress');
      pollFails = 0;
      replaceLog = p.log ?? '';
      if (p.done) {
        clearInterval(replaceTimer);
        replaceTimer = null;
        busy = false;
        actionScope = 'replace';
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
            + 'всего, не в них, а в сети: если она не пропускает UDP, AmneziaWG в ней не поднимется ни с каким сервером.';
        }
        await refresh();
      }
    } catch {
      pollLost('replace');
    }
  }

  // obtainToken() — install-токен для мастера: движок отдаёт существующий или выпускает новый
  // (install_token, admin). Нужен и после сброса, и для «Настроить заново»: успешная установка
  // токен снимает как одноразовый, поэтому без этого шага мастер доходил до последней кнопки и
  // получал «токен не найден — запустите bootstrap по SSH». Пусто → ссылку не выдумываем.
  async function obtainToken() {
    try {
      const t = await cheburnet('install_token');
      return t.token ?? '';
    } catch (e) {
      needLogin(e, 'Повторная настройка', 'danger');
      return '';
    }
  }

  // «Настроить заново» из панели: сначала токен, потом мастер — иначе человек заполнит все поля и
  // упрётся в отказ на последнем шаге. Без токена мастер всё равно откроем (там честно скажут,
  // что делать), но пробовать получить его обязаны.
  async function reinstall() {
    const t = await obtainToken();
    if (t) {
      location.search = `?token=${encodeURIComponent(t)}`;
      return;
    }
    onReinstall();
  }

  // Factory reset: двойное подтверждение — ввод слова RESET руками. Ждём ЗАВЕРШЕНИЯ (тот же
  // канал install_progress, что у остальных фоновых операций): раньше панель говорила «запущен» и
  // на этом заканчивала, а человек оставался наедине с роутером в промежуточном состоянии.
  let resetPhase = $state('idle'); // idle | running | ok | fail
  let resetToken = $state('');
  let resetTimer = null;
  // Движок принимает ровно "RESET" (регистр важен) — панель приводит ввод сама: осознанность даёт
  // набранное руками слово, а не раскладка Shift'а. Иначе «reset» оставлял кнопку серой молча.
  const resetOk = $derived(resetWord.trim().toUpperCase() === 'RESET');
  const factoryReset = () =>
    admin('Сброс cheburnet', async () => {  // scope 'danger' — сообщение остаётся в опасной зоне
      await cheburnet('factory_reset', { confirm: resetWord.trim().toUpperCase() });
      action = 'Снимаю конфигурацию — роутер вернётся к обычной маршрутизации.';
      resetWord = '';
      resetArmed = false;
      resetPhase = 'running';
      resetTimer = setInterval(pollReset, 2000);
    }, 'danger');

  async function pollReset() {
    try {
      const p = await cheburnet('install_progress');
      pollFails = 0;
      if (!p.done) return;
      clearInterval(resetTimer); resetTimer = null;
      actionScope = 'danger';
      if (p.result === 'ok') {
        resetPhase = 'ok';
        action = 'Готово: конфигурация cheburnet снята, роутер вернулся к обычной маршрутизации.';
        resetToken = await obtainToken();
      } else {
        resetPhase = 'fail';
        action = 'Сброс завершился с ошибкой — часть настройки могла остаться. '
          + 'Соберите диагностику (блок «Если что-то не работает») и пришлите её.';
      }
      await refresh();
    } catch { pollLost('danger'); }
  }

  refresh();
  if (loggedIn) loadDomains();
  // 15 с, не чаще: каждый опрос — это спавн rpcd-скрипта + shell-батч на роутере (слабое железо).
  timer = setInterval(refresh, 15000);
  onDestroy(() => {
    if (timer) clearInterval(timer);
    if (replaceTimer) clearInterval(replaceTimer);
    if (switchTimer) clearInterval(switchTimer);
    if (resetTimer) clearInterval(resetTimer);
  });

  // In-place смена туннеля: приносим только конфиг нового туннеля, домены/DNS берутся из
  // сохранённого (мастер не проходим). run.uc делает snapshot → teardown прежнего → apply → health
  // → commit/rollback, прогресс — тот же канал install_progress. При сбое ПРЕЖНИЙ туннель
  // возвращается автоматически. Одна функция на все шесть переходов — метод берём из каталога.
  async function switchTo(p) {
    const conf = (switchConfs[p.id] ?? '').trim();
    actionScope = 'switch';
    const bad = checkConf(p.id, conf);
    if (bad) {
      action = bad;
      return;
    }
    switchTarget = p.id;
    busy = true; action = ''; switchLog = '';
    try {
      await cheburnet(p.switchMethod, { [p.confKey]: conf });
      switchPhase = 'running';
      switchTimer = setInterval(pollSwitch, 2000);
    } catch (e) {
      needLogin(e, 'Переключение', 'switch');
    }
  }

  async function pollSwitch() {
    try {
      const p = await cheburnet('install_progress');
      pollFails = 0;
      switchLog = p.log ?? '';
      if (p.done) {
        clearInterval(switchTimer); switchTimer = null; busy = false;
        actionScope = 'switch';
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
    } catch { pollLost('switch'); }
  }

</script>

<!-- Результат действия печатается только у той группы кнопок, которая его вызвала (actionScope).
     Одно место на всю страницу означало, что итог нажатия верхней кнопки появлялся под опасной
     зоной — то есть там, куда человек не смотрит. -->
{#snippet actionNote(scope)}
  {#if action && actionScope === scope}<p data-slot="action-note" class="text-muted-foreground">{action}</p>{/if}
{/snippet}

{#snippet modeLabel()}{s.mode === 'travel' ? 'В поездке' : 'Дома'}{/snippet}

<div class="flex flex-col">
  <SectionTitle>Состояние</SectionTitle>

  {#if error}<p class="mb-3 text-destructive">{error}</p>{/if}

  {#if s}
    <!-- Ответ, а не приборная панель: человек приходит с одним вопросом — «работает?». Крупная
         фраза и одна строка контекста, детали — в «Подробностях» внизу карточки. -->
    <Card.Root data-slot="hero">
      {#if s.paused}
        <!-- Аварийный режим — ВЫШЕ всего: молча снятая защита недопустима. -->
        <Card.Header>
          <Card.Title class="flex items-center gap-2 text-destructive"><ShieldOff class="size-7" aria-hidden="true" />Защита выключена</Card.Title>
          <Card.Description>Интернет идёт напрямую, мимо VPN: трафик виден провайдеру,
            kill-switch и разделение по списку сняты. Настройки сохранены.</Card.Description>
        </Card.Header>
        <div><Button onclick={resumeProtection} disabled={busy}><ShieldCheck />Вернуть защиту</Button></div>
        {@render actionNote('emergency')}
      {:else if hero === 'down'}
        <Card.Header>
          <Card.Title class="flex items-center gap-2 text-destructive"><ShieldAlert class="size-7" aria-hidden="true" />Туннель не работает</Card.Title>
          <Card.Description>{active.name} · открываются только сайты из списка «напрямую»</Card.Description>
          <Card.Action><Badge variant="destructive">Нет связи</Badge></Card.Action>
        </Card.Header>

        <Alert.Root variant="destructive">
          <StatusIcon tone="bad" />
          <Alert.Body>
            <Alert.Description>
              Сначала <a href="#services-group" onclick={() => (servicesOpen = true)}>перезапустите
              туннель</a>. Не помогло — {#if active.legacy}<a href="#switch-tunnel" onclick={() => (tunnelOpen = true)}>переключитесь
              на другой туннель</a>: сервер {active.name} больше не меняется{:else}<a href="#replace-tunnel" onclick={() => (tunnelOpen = true)}>вставьте
              свежий конфиг</a>{/if}.
            </Alert.Description>
          </Alert.Body>
        </Alert.Root>

        {#if s.mode === 'travel'}
          <p class="text-sm text-muted-foreground">Режим «в поездке»: резервный путь для DNS отключён намеренно —
            в чужой сети наружу не должно уходить ничего. Поэтому сейчас не открывается ничего.</p>
        {:else}
          <p class="text-sm text-muted-foreground">Пока туннель лежит, DNS работает резервным путём мимо туннеля:
            запросы зашифрованы, но провайдер видит факт обращения к резолверу. Туннель поднимется —
            сторож вернёт DNS в него сам.</p>
        {/if}

        {#if fallback?.action === 'switch'}
          <p class="text-sm text-muted-foreground">Попробуйте поддерживаемый туннель:
            {#each fallback.targets as t, i}{#if i > 0}, {/if}<a href="#switch-tunnel"
              onclick={() => { switchPick = t; tunnelOpen = true; }}>{protocolInfo(t).name}</a>{/each}.
            Не поднимется — прежний вернётся сам.</p>
        {/if}

        <!-- Аварийная кнопка — ТОЛЬКО когда туннель правда не работает, и последней. -->
        <p class="text-sm text-muted-foreground">Ничего не помогло, а интернет нужен сейчас? Можно временно
          выключить защиту — трафик пойдёт напрямую, мимо VPN. Настройки сохранятся.</p>
        <div><Button variant="destructive-outline" disabled={busy} onclick={pauseProtection}><ShieldOff />Выключить защиту</Button></div>
        {@render actionNote('emergency')}
      {:else if hero === 'up' && active.full}
        <!-- У Full-тира нет рукопожатия — не обещаем «всё работает». Протокол заморожен (ADR 0010). -->
        <Card.Header>
          <Card.Title class="flex items-center gap-2"><ShieldCheck class="size-7 text-success" aria-hidden="true" />{active.name} активен</Card.Title>
          <Card.Description>Трафик идёт через туннель</Card.Description>
          <Card.Action><Badge variant="outline">{@render modeLabel()}</Badge></Card.Action>
        </Card.Header>
        <p class="text-sm text-muted-foreground">{active.name} больше не поддерживается: сменить его сервер нельзя.
          Перейдите на <a href="#switch-tunnel" onclick={() => (tunnelOpen = true)}>AmneziaWG</a> — при сбое прежний вернётся сам.</p>
      {:else}
        <Card.Header>
          <Card.Title class="flex items-center gap-2"><ShieldCheck class="size-7 text-success" aria-hidden="true" />Всё работает</Card.Title>
          <Card.Description>{active.name} · {tunnelRowText(s)}</Card.Description>
          <Card.Action><Badge variant="success">{@render modeLabel()}</Badge></Card.Action>
        </Card.Header>
      {/if}

      <!-- Красная тревога — ТОЛЬКО когда direct-доменов нет вовсе. -->
      {#if s.installed && s.direct_domains === 0}
        <Alert.Root variant="destructive">
          <StatusIcon tone="bad" />
          <Alert.Body>
            <Alert.Description>Список «сайты напрямую» пуст — весь трафик идёт через VPN (безопасно,
              но медленнее). Впишите свои сайты ниже или подтяните готовый список.</Alert.Description>
          </Alert.Body>
        </Alert.Root>
      {/if}

      {#if s.installed && s.forced?.length > 0}
        <Alert.Root variant="warning">
          <StatusIcon tone="warn" />
          <Alert.Body>
            <Alert.Description>Роутер слабее рекомендуемого — установлено по вашему решению
              ({s.forced.map((f) => FORCED_LABELS[f] ?? f).join(', ')}). Работает, но стабильность
              не гарантируется.</Alert.Description>
          </Alert.Body>
        </Alert.Root>
      {/if}

      <details class="border-t border-border pt-3">
        <summary class="cursor-pointer text-sm text-muted-foreground">Подробности</summary>
        <div class="mt-3">
          <StatusList>
            <StatusRow label="Сайты напрямую" value={s.direct_domains} />
            <StatusRow label="Импортированный список"
                       value={s.direct_list_loaded ? `${s.imported_domains} доменов` : 'не загружен'} />
            <StatusRow label="Туннель ({active.name})" tone={s.tunnel_health === 'up' ? 'ok' : 'bad'} value={tunnelRowText(s)} />
            <StatusRow label="DNS" tone={s.dns_up ? 'ok' : 'bad'} value={s.dns_up ? 'работает' : 'нет'} />
            <StatusRow label="Шифрованный DNS" tone={s.doh_up ? 'ok' : 'bad'} value={s.doh_up ? 'работает' : 'нет'} />
            {#if s.wireless_present}
              <StatusRow label="Wi-Fi (SSID)" value={s.ssid || '—'} />
            {/if}
            <StatusRow label="DNS-фильтрация"
                       value={s.dns_provider_desc ? s.dns_provider_desc.name : (s.dns_provider ?? '—')} />
          </StatusList>
        </div>
      </details>
    </Card.Root>

    <!-- Вход — кнопкой у заголовка группы: действие само спросит пароль, отдельный блок не нужен. -->
    <SectionTitle>
      Управление
      {#snippet action()}
        {#if loggedIn}
          <Button variant="ghost" size="sm" onclick={doLogout}><LogOut />Выйти</Button>
        {:else}
          <span id="login" data-slot="login-gate">
            <Button variant="ghost" size="sm" onclick={() => (loginOpen = true)}><LogIn />Войти</Button>
          </span>
        {/if}
      {/snippet}
    </SectionTitle>

    <Card.Root>
      <F.Field>
        <F.Title>Режим работы</F.Title>
        <ButtonGroup width="full" aria-label="Режим работы">
          <Button variant={s.mode !== 'travel' ? 'default' : 'outline'} aria-pressed={s.mode !== 'travel'} disabled={busy}
                  onclick={() => s.mode === 'travel' && setMode('home')}><House />Дома</Button>
          <Button variant={s.mode === 'travel' ? 'default' : 'outline'} aria-pressed={s.mode === 'travel'} disabled={busy}
                  onclick={() => s.mode !== 'travel' && setMode('travel')}><Plane />В поездке</Button>
        </ButtonGroup>
        <F.Description>Дома: список сайтов идёт напрямую. В поездке: всё через туннель.</F.Description>
      </F.Field>

      <!-- Свой список — главная настройка продукта: поменять сайт не должно стоить переустановки. -->
      <Field label="Сайты напрямую — ваш список"
             hint="Домен (example.com) покрывает и все его поддомены, каждый сайт — своей строкой. Остальное идёт через туннель.">
        {#if loggedIn && domainsLoaded}
          <Textarea bind:value={userDomainsText} rows="3" disabled={busy}
                    placeholder={'example.com\nexample.org'} />
        {:else}
          <Textarea rows="3" disabled
                    placeholder={loggedIn ? 'Загружаю список…' : 'Войдите, чтобы увидеть и изменить список'} />
        {/if}
      </Field>

      <div class="flex flex-col gap-2">
        <!-- Без входа кнопка не серая, а ведёт ко входу: серая читается как «сломано». -->
        <Button disabled={busy || (loggedIn && !domainsLoaded)}
                onclick={() => (loggedIn ? saveDomains() : (loginOpen = true))}>Сохранить список</Button>
        <Button variant="outline" disabled={busy} onclick={updateList}>Обновить готовый список</Button>
        <p class="text-sm text-muted-foreground">Готовый список популярных сайтов добавится к вашему.</p>
      </div>
      {@render actionNote('manage')}
    </Card.Root>

    <SectionTitle>Настройки</SectionTitle>
    <Card.Root variant="flush">
      <DetailsGroup id="services-group" bind:open={servicesOpen} icon={SlidersHorizontal}
                    summary="Сервисы и фильтрация"
                    description={s.dns_provider_desc ? `Фильтрация: ${s.dns_provider_desc.name}` : 'Перезапуск и фильтрация'}>
        <p class="text-sm text-muted-foreground">Перезапуск — первое, что стоит попробовать, если что-то отвалилось.</p>
        <ButtonGroup width="full" aria-label="Перезапустить">
          <Button variant="outline" disabled={busy} onclick={() => restart('vpn', 'туннель')}>Туннель</Button>
          <Button variant="outline" disabled={busy} onclick={() => restart('dns', 'DNS')}>DNS</Button>
          <Button variant="outline" disabled={busy} onclick={() => restart('doh', 'шифрованный DNS')}>Шифр. DNS</Button>
        </ButtonGroup>
        {@render actionNote('restart')}

        <Field label="Блокировка рекламы / взрослого контента"
               hint="«Семейный» блокирует сайты 18+ и включает безопасный поиск.">
          <NativeSelect bind:value={providerSel} disabled={busy}>
            {#each s.dns_providers ?? [] as p}
              <option value={p.id}>{p.name} — {p.description}</option>
            {/each}
          </NativeSelect>
        </Field>
        <div>
          <Button variant="outline" disabled={busy || !providerSel || providerSel === s.dns_provider} onclick={setProvider}>Применить</Button>
        </div>
        {@render actionNote('dns')}
      </DetailsGroup>

      <DetailsGroup id="servers-group" bind:open={serversOpen} icon={Globe}
                    summary="Серверы — выбрать страну" description="Сохранённые серверы и автосмена">
        <Servers {loggedIn} protocol={s.protocol} onDenied={serversDenied} onChanged={refresh} />
      </DetailsGroup>

      <DetailsGroup id="tunnel-group" bind:open={tunnelOpen} icon={KeyRound}
                    summary="Туннель — заменить сервер или сменить протокол" description={active.name}>
        {#if active.legacy}
          <SectionTitle id="replace-tunnel">{active.name} больше не поддерживается</SectionTitle>
          <p class="text-sm">Туннель работает, но сменить его сервер нельзя.
            Переключитесь на AmneziaWG в блоке «Сменить туннель» ниже — при сбое {active.name} вернётся сам.</p>
        {:else}
          <SectionTitle id="replace-tunnel">Замена сервера ({active.name})</SectionTitle>
          <p class="text-sm text-muted-foreground">Вставьте свежий конфиг от своего сервера.
            Не отзовётся — прежний вернётся сам.</p>
          <Field label={active.confLabel}>
            <Textarea bind:value={replaceConf} rows="5" class="font-mono" disabled={busy} placeholder={active.placeholder} />
            <ConfCheck id={active.id} text={replaceConf} />
          </Field>
          {#if active.file}
            <FileButton accept=".conf,text/plain" onchange={onReplaceFile} disabled={busy}>Загрузить .conf</FileButton>
          {/if}
          <div>
            <Button disabled={busy || replaceConf.trim().length === 0} onclick={replaceTunnel}>
              {replacePhase === 'running' ? 'Применяю…' : 'Заменить конфиг'}
            </Button>
          </div>
          {#if replacePhase === 'running'}
            <p class="flex items-center gap-2"><Spinner /> Применяю новый конфиг — при сбое прежний вернётся автоматически.</p>
          {/if}
          {@render actionNote('replace')}
          {#if replaceLog && replacePhase !== 'idle'}
            <details open={replacePhase === 'fail'}>
              <summary class="cursor-pointer text-sm text-muted-foreground">Журнал замены</summary>
              <LogView text={replaceLog} class="mt-2" />
            </details>
          {/if}
        {/if}

        {#if targets.length > 0}
          <SectionTitle id="switch-tunnel">Сменить туннель</SectionTitle>
          <p class="text-sm text-muted-foreground">Сейчас активен <strong>{active.name}</strong>. Сайты, DNS и
            режим сохранятся. Не поднимется — прежний вернётся сам.</p>
          {#each targets as p}
            <RadioCard bind:group={switchPick} value={p.id} disabled={busy}>
              <strong>{p.symptom}</strong> — {p.why}
              <br /><small class="text-muted-foreground">Протокол: {p.name}</small>
            </RadioCard>
          {/each}
          <Field label={pick.confLabel}>
            <Textarea bind:value={switchConfs[switchPick]} rows="4" class="font-mono" disabled={busy} placeholder={pick.placeholder} />
            <ConfCheck id={pick.id} text={switchConfs[switchPick]} />
          </Field>
          {#if pick.file}
            <FileButton accept=".conf,text/plain" onchange={(e) => onSwitchFile(e, switchPick)} disabled={busy}>Загрузить .conf</FileButton>
          {/if}
          <div>
            <Button disabled={busy || (switchConfs[switchPick] ?? '').trim().length === 0} onclick={() => switchTo(pick)}>
              {switchPhase === 'running' && switchTarget === switchPick ? 'Переключаю…' : `Переключиться на ${pick.name}`}
            </Button>
          </div>
          {#if switchPhase === 'running'}
            <p class="flex items-center gap-2"><Spinner /> Поднимаю {protocolInfo(switchTarget).name} — при сбое
              вернётся {active.name}.</p>
          {/if}
          {#if switchLog && switchPhase !== 'idle'}
            <details open={switchPhase === 'fail'}>
              <summary class="cursor-pointer text-sm text-muted-foreground">Журнал переключения</summary>
              <LogView text={switchLog} class="mt-2" />
            </details>
          {/if}
        {/if}
        <!-- ЗА пределами блока смены: после ухода на AWG блок исчезает, а сообщение должно остаться. -->
        {@render actionNote('switch')}
      </DetailsGroup>
    </Card.Root>

    <!-- Поддержка — ПЕРЕД опасной зоной и не свёрнута: путь «спросить» находится раньше «сбросить». -->
    <SectionTitle id="support">Если что-то не работает</SectionTitle>
    <Card.Root variant="flush">
      <Item.Root class="rounded-none">
        <Item.Media variant="icon" class="text-primary"><LifeBuoy /></Item.Media>
        <Item.Content>
          <Item.Title class="text-base font-semibold">Напишите в Telegram</Item.Title>
          <Item.Description><a href={SUPPORT.telegramUrl} target="_blank" rel="noreferrer">{SUPPORT.telegram}</a> — отвечаю всем</Item.Description>
        </Item.Content>
      </Item.Root>
      <Item.Root class="rounded-none">
        <Item.Media variant="icon" class="text-primary"><Stethoscope /></Item.Media>
        <Item.Content>
          <Item.Title class="text-base font-semibold">Диагностика</Item.Title>
          <Item.Description>Пароли и ключи вырезаются — файл вы увидите до отправки.</Item.Description>
        </Item.Content>
        <Item.Footer>
          <Button variant="outline" disabled={busy || diagPhase === 'running'} onclick={collectDiagnostics}>
            {diagPhase === 'running' ? 'Собираю…' : 'Собрать диагностику'}
          </Button>
          {#if diagPhase === 'ok'}
            <Button variant="outline" onclick={downloadDiagnostics}>Скачать файл</Button>
          {/if}
        </Item.Footer>
      </Item.Root>
      {#if (action && actionScope === 'support') || diagPhase === 'ok'}
        <div class="flex flex-col gap-3 p-4">
          {@render actionNote('support')}
          {#if diagPhase === 'ok'}
            <p class="text-sm text-muted-foreground">
              {#if diagRemoved.length > 0}
                Вырезано: {diagRemoved.join('; ')}. Адрес сервера оставлен — без него причину не найти.
              {:else}
                Секретов известных форм не нашлось. Всё равно пролистайте текст перед отправкой.
              {/if}
            </p>
            <details open>
              <summary class="cursor-pointer text-sm text-muted-foreground">Что будет отправлено</summary>
              <LogView text={diagText} class="mt-2" />
            </details>
          {/if}
        </div>
      {/if}
    </Card.Root>
    <p class="mt-2 px-1 text-sm text-muted-foreground">Проект и документация —
      <a href={SUPPORT.page} target="_blank" rel="noreferrer">на GitHub</a>.</p>

    <SectionTitle>Поддержать проект</SectionTitle>
    <Card.Root variant="flush">
      <Item.Root class="rounded-none">
        <Item.Media variant="icon" class="text-primary"><Heart /></Item.Media>
        <Item.Content>
          <Item.Title class="text-base font-semibold">cheburnet бесплатный и делается одним человеком</Item.Title>
          <Item.Description>Если роутер вам помогает, поддержите разработку — это время на новые функции и ответы на вопросы.</Item.Description>
        </Item.Content>
        <Item.Footer>
          <Button variant="outline" href={SUPPORT.donateUrl} target="_blank" rel="noreferrer">Поддержать донатом</Button>
          <Button variant="ghost" href={SUPPORT.page} target="_blank" rel="noreferrer">Звезда на GitHub</Button>
        </Item.Footer>
      </Item.Root>
    </Card.Root>

    <SectionTitle>Обслуживание</SectionTitle>
    <Card.Root variant="flush">
      <Item.Root class="rounded-none">
        <Item.Media variant="icon" class="text-primary"><RotateCcw /></Item.Media>
        <Item.Content>
          <Item.Title class="text-base font-semibold">Мастер настройки</Item.Title>
          <!-- Подпись обязательна: без неё кнопка читается как второй способ всё стереть. -->
          <Item.Description>Пройти заново. Текущая настройка работает до конца установки.</Item.Description>
        </Item.Content>
        <Item.Footer><Button variant="outline" onclick={reinstall}>Настроить заново</Button></Item.Footer>
      </Item.Root>

      <DetailsGroup id="danger-group" bind:open={dangerOpen} tone="danger" icon={TriangleAlert}
                    summary="Опасная зона" description="Сбросить настройку cheburnet">
        {#if !resetArmed}
          <div><Button variant="destructive-outline" disabled={busy} onclick={() => (resetArmed = true)}>Сбросить настройку cheburnet…</Button></div>
        {:else}
          <!-- Честно перечисляем и то, что останется: «сбросить всё» читают как «удалить программу». -->
          <p class="text-destructive">Роутер вернётся к обычной маршрутизации — весь трафик пойдёт напрямую, без VPN.</p>
          <ul class="list-disc pl-5 text-sm">
            <li><strong>Снимется:</strong> туннель, разделение трафика, шифрованный DNS, фильтрация.</li>
            <li><strong>Останется:</strong> программа и эта панель, Wi-Fi, пароль роутера.</li>
          </ul>
          <p class="text-sm text-muted-foreground">Настроить заново можно сразу отсюда. Удалить полностью —
            <Kbd>apk del cheburnet</Kbd> по SSH.</p>
          <Field label="Введите слово RESET для подтверждения">
            <Input type="text" bind:value={resetWord} placeholder="RESET" />
          </Field>
          <div class="flex flex-wrap gap-3">
            <Button variant="outline" class="min-w-35 flex-1" disabled={busy}
                    onclick={() => { resetArmed = false; resetWord = ''; }}>Отмена</Button>
            <Button variant="destructive" class="min-w-35 flex-1" disabled={busy || !resetOk} onclick={factoryReset}>
              Подтвердить сброс
            </Button>
          </div>
        {/if}
        {#if resetPhase === 'running'}
          <p class="flex items-center gap-2"><Spinner /> Снимаю конфигурацию — роутер на несколько секунд
            перезапустит сеть.</p>
        {/if}
        {@render actionNote('danger')}
        {#if resetPhase === 'ok'}
          {#if resetToken}
            <p class="font-semibold text-success">Можно настраивать заново:
              <a href="?token={encodeURIComponent(resetToken)}">открыть мастер настройки</a>.</p>
          {:else}
            <p class="text-sm text-muted-foreground">Чтобы настроить заново, запустите команду установки по SSH —
              она напечатает новую ссылку на мастер.</p>
          {/if}
        {/if}
      </DetailsGroup>
    </Card.Root>
  {:else}
    <Card.Root>
      <Skeleton class="h-8 w-2/3" />
      <Skeleton class="h-4 w-1/2" />
    </Card.Root>
  {/if}
</div>

<Modal bind:open={loginOpen}>
  <h3 class="font-display text-xl">Вход в управление</h3>
  <p class="text-sm text-muted-foreground">Пароль администратора роутера (root) — тот, что задан при установке.</p>
  <Field label="Пароль">
    <Input
      type="password"
      bind:el={loginInput}
      bind:value={loginPass}
      autocomplete="current-password"
      onkeydown={(e) => e.key === 'Enter' && doLogin()}
    />
  </Field>
  {#if loginError}<p class="text-destructive">{loginError}</p>{/if}
  <div class="flex flex-wrap gap-3">
    <Button variant="outline" class="flex-1" onclick={() => (loginOpen = false)}>Отмена</Button>
    <Button class="flex-1" disabled={loginPass.length === 0} onclick={doLogin}>Войти</Button>
  </div>
</Modal>
