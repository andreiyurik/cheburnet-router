<script>
  import { onDestroy } from 'svelte';
  import { cheburnet, login, isLoggedIn, logout, isAccessDenied } from '../ubus.js';
  import { hs, FORCED_LABELS, heroKind, tunnelFallback, switchTargets, tunnelRowText,
           explainFullTierFail, fullMissingText, protocolInfo, checkConf, BRUTAL_WARNING,
           withDeclaredSpeed, SPEED_DEFAULTS, SUPPORT, parseDomains } from '../logic.js';
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
  let fullPhase = $state('idle'); // догрузка компонента: idle | running | ok | fail
  let fullLog = $state('');
  // Смена туннеля: конфиги хранятся ПО ПРОТОКОЛАМ (переключение выбора не теряет вставленное).
  let switchConfs = $state({ awg: '', reality: '', hysteria2: '' });
  // switchPick — ВЫБРАННОЕ направление (радио), switchTarget — то, что уже переключается.
  // Раньше блоков было по одному на протокол: три похожих поля для ссылок на одной странице, и
  // вставить в чужое — обычное дело. Теперь как в мастере: сначала выбор по симптому, потом одно поле.
  let switchPick = $state('');
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
  // Чего не хватает железу для Full-тира (status.full_missing) — человеческими словами.
  const fullMissing = $derived(fullMissingText(s?.full_missing));
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
      await cheburnet(active.replaceMethod, { [active.confKey]: hy2Conf(active.id, conf) });
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
            + 'всего, не в них: попробуйте другой туннель — блок «Сменить туннель» ниже.';
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
    if (fullTimer) clearInterval(fullTimer);
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
      await cheburnet(p.switchMethod, { [p.confKey]: hy2Conf(p.id, conf) });
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

  // Full-тир (opt-in): кнопка догружает компонент sing-box фоном. Прогресс — тот же канал
  // install_progress. Работающий туннель при этом не трогается (ставим только пакет).
  async function enableFullTier() {
    busy = true; action = ''; fullLog = '';
    try {
      await cheburnet('install_full_tier');
      fullPhase = 'running';
      fullTimer = setInterval(pollFull, 2000);
    } catch (e) {
      needLogin(e, 'Установка запасного туннеля', 'full');
    }
  }

  async function pollFull() {
    try {
      const p = await cheburnet('install_progress');
      pollFails = 0;
      fullLog = p.log ?? '';
      if (p.done) {
        clearInterval(fullTimer); fullTimer = null; busy = false;
        actionScope = 'full';
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
    } catch { pollLost('full'); }
  }
</script>

<!-- Результат действия печатается только у той группы кнопок, которая его вызвала (actionScope).
     Одно место на всю страницу означало, что итог нажатия верхней кнопки появлялся под опасной
     зоной — то есть там, куда человек не смотрит. -->
{#snippet actionNote(scope)}
  {#if action && actionScope === scope}<p data-slot="action-note" class="text-muted-foreground">{action}</p>{/if}
{/snippet}

<!-- Скорость канала (Brutal) — сниппет, потому что рендерится РЯДОМ С ПОЛЕМ, к которому относится:
     в замене сервера, если Hysteria2 уже активен, и в смене туннеля, если на него переключаются.
     Раньше блок стоял единожды в конце страницы — то есть НИЖЕ кнопок, которые его применяют, и
     человек нажимал раньше, чем узнавал о настройке. Оба места одновременно не выпадают: активный
     протокол в targets не попадает, поэтому общее состояние declareSpeed однозначно.
     Поле не голое сознательно: завышенная цифра делает связь ХУЖЕ и молча (см. ADR 0004). -->
{#snippet speedFields()}
  <h4 class="mt-4 mb-1 text-sm font-semibold">Скорость канала</h4>
  <RadioCard bind:group={declareSpeed} value={false} disabled={busy}>
    <strong>Подбирать автоматически</strong> — рекомендуем.
  </RadioCard>
  <RadioCard bind:group={declareSpeed} value={true} disabled={busy}>
    <strong>Указать вручную</strong> — иногда выжимает больше на канале с потерями.
  </RadioCard>
  {#if declareSpeed}
    <Alert.Root variant="warning" class="my-3">
      <Alert.Description>{BRUTAL_WARNING}</Alert.Description>
    </Alert.Root>
    <Field label="Скорость приёма (Мбит/с)" class="mb-3">
      <Input type="number" min="1" max="10000" class="w-32" bind:value={speedDown} disabled={busy} />
    </Field>
    <Field label="Скорость отдачи (Мбит/с)">
      <Input type="number" min="1" max="10000" class="w-32" bind:value={speedUp} disabled={busy} />
    </Field>
  {/if}
{/snippet}

<!-- Кнопка сегмента «Режим работы»: показывает ТЕКУЩЕЕ состояние (aria-pressed), а не то, куда
     переключит. Кнопка-переключатель и строка сводки рядом называли одно и то же по-разному. -->
{#snippet segment(label, pressed, onclick)}
  <button
    type="button"
    aria-pressed={pressed}
    disabled={busy}
    class="h-10 flex-1 border border-border px-4 text-sm transition-colors first:rounded-l-md last:-ml-px last:rounded-r-md
           disabled:pointer-events-none aria-pressed:border-primary aria-pressed:bg-primary aria-pressed:font-semibold
           aria-pressed:text-primary-foreground not-aria-pressed:bg-card not-aria-pressed:hover:border-primary
           not-aria-pressed:disabled:opacity-50"
    {onclick}
  >{label}</button>
{/snippet}

<div class="flex flex-col">
  <SectionTitle>Состояние</SectionTitle>

  {#if error}<p class="mt-3 text-destructive">{error}</p>{/if}

  {#if s}
    <!-- Ответ, а не приборная панель: человек приходит с одним вопросом — «работает?». Сначала
         крупная фраза и одна строка контекста, детали — в «Подробностях» ниже. -->
    <div class="mt-4 flex flex-col gap-3">
      {#if s.paused}
        <!-- Аварийный режим — ВЫШЕ всего: это главное, что сейчас происходит с роутером. Молча
             снятая защита недопустима, поэтому говорим прямо, что именно выключено. -->
        <p class="font-display text-3xl text-destructive">Защита выключена</p>
        <p class="text-muted-foreground">Интернет идёт напрямую, мимо VPN: трафик виден провайдеру,
          kill-switch и разделение по списку сняты. Настройки сохранены.</p>
        <div><Button onclick={resumeProtection} disabled={busy}>Вернуть защиту</Button></div>
        {@render actionNote('emergency')}
      {:else if hero === 'down'}
        <p class="font-display text-3xl text-destructive">Туннель не работает</p>
        <p class="text-muted-foreground">{active.name} · открываются только сайты из списка «напрямую»</p>

        <Alert.Root variant="destructive">
          <StatusIcon tone="bad" />
          <Alert.Body>
            <Alert.Description>
              Сначала <a href="#services-group" onclick={() => (servicesOpen = true)}>перезапустите
              туннель</a>. Не помогло — <a href="#replace-tunnel" onclick={() => (tunnelOpen = true)}>вставьте
              свежий конфиг</a>.
            </Alert.Description>
          </Alert.Body>
        </Alert.Root>

        <!-- Честность о деградации: DNS сейчас работает РЕЗЕРВНЫМ путём мимо туннеля, и человек
             имеет право знать, что изменилось в его приватности. В поездке резервного пути нет. -->
        {#if s.mode === 'travel'}
          <p class="text-sm text-muted-foreground">Режим «в поездке»: резервный путь для DNS отключён намеренно —
            в чужой сети наружу не должно уходить ничего. Поэтому сейчас не открывается ничего.</p>
        {:else}
          <p class="text-sm text-muted-foreground">Пока туннель лежит, DNS работает резервным путём мимо туннеля:
            запросы зашифрованы, но провайдер видит факт обращения к резолверу. Туннель поднимется —
            сторож вернёт DNS в него сам.</p>
        {/if}

        <!-- Ведём к запасному пути ровно тогда, когда он нужен. ВАЖНО: с AmneziaWG предлагаем
             именно VLESS+Reality: Hysteria2 тоже UDP и падает вместе с AWG. -->
        {#if fallback?.action === 'install'}
          <p class="text-sm text-muted-foreground">Не помог и свежий конфиг? Похоже, сеть режет сам протокол AmneziaWG (он работает по UDP).
            Тогда помогает <a href="#full-tier" onclick={() => (tunnelOpen = true)}>добавить VLESS+Reality</a> —
            снаружи он выглядит как обычный HTTPS.</p>
        {:else if fallback?.action === 'switch'}
          <p class="text-sm text-muted-foreground">Не помог и свежий конфиг? Значит дело, скорее всего, не в сервере, а в сети —
            попробуйте другой туннель:
            {#each fallback.targets as t, i}{#if i > 0}, {/if}<a href="#switch-tunnel"
              onclick={() => { switchPick = t; tunnelOpen = true; }}>{protocolInfo(t).name}</a>{/each}.
            Не поднимется — прежний вернётся сам.</p>
        {/if}

        <!-- Аварийная кнопка — ТОЛЬКО когда туннель правда не работает, и последней: предлагать
             снять защиту на исправной системе значит подталкивать к тому, чего не просили. -->
        <p class="text-sm text-muted-foreground">Ничего не помогло, а интернет нужен сейчас? Можно временно
          выключить защиту — трафик пойдёт напрямую, мимо VPN. Настройки сохранятся.</p>
        <div><Button variant="destructive-outline" disabled={busy} onclick={pauseProtection}>Выключить защиту</Button></div>
        {@render actionNote('emergency')}
      {:else if hero === 'up' && active.full}
        <!-- Формулировка слабее, чем у AWG, ОСОЗНАННО: у Full-протоколов нет рукопожатия — видно,
             что туннель поднят, но не что сервер отвечает. Не обещаем «всё работает». -->
        <p class="font-display text-3xl">{active.name} активен</p>
        <p class="text-muted-foreground">Трафик идёт через туннель · режим {s.mode === 'travel' ? '«в поездке»' : '«дома»'}
          {#if s.full_capable && !s.full_installed}
            · <a href="#full-tier" onclick={() => (tunnelOpen = true)}>другие протоколы</a>
          {:else if targets.length > 0}
            · <a href="#switch-tunnel" onclick={() => (tunnelOpen = true)}>сменить</a>
          {/if}</p>
        <p class="text-sm text-muted-foreground">Сайты не открываются? Сервер мог отключиться — вставьте свежий
          конфиг, прежний вернётся сам при неудаче.</p>
      {:else}
        <p class="font-display text-3xl">Всё работает</p>
        <p class="text-muted-foreground">{active.name} · {tunnelRowText(s)} · режим {s.mode === 'travel' ? '«в поездке»' : '«дома»'}
          {#if s.full_capable && !s.full_installed}
            · <a href="#full-tier" onclick={() => (tunnelOpen = true)}>другие протоколы</a>
          {:else if targets.length > 0}
            · <a href="#switch-tunnel" onclick={() => (tunnelOpen = true)}>сменить</a>
          {/if}</p>
      {/if}

      <!-- Красная тревога — ТОЛЬКО когда direct-доменов нет вовсе: тогда split не работает и весь
           трафик идёт в туннель. Есть свои домены — тревога ложна. -->
      {#if s.installed && s.direct_domains === 0}
        <Alert.Root variant="destructive">
          <StatusIcon tone="bad" />
          <Alert.Body>
            <Alert.Description>Список «сайты напрямую» пуст — весь трафик идёт через VPN (безопасно,
              но медленнее). Впишите свои сайты ниже или подтяните готовый список.</Alert.Description>
          </Alert.Body>
        </Alert.Root>
      {/if}

      <!-- Роутер поставлен с пропуском проверок железа (install.json.forced): не поломка, но при
           разборе «тормозит/отваливается» это первое, куда смотреть. -->
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

      <details class="mt-1">
        <summary class="cursor-pointer text-sm text-muted-foreground">Подробности</summary>
        <StatusList>
          <StatusRow label="Сайты напрямую" value={s.direct_domains} />
          <StatusRow label="Импортированный список"
                     value={s.direct_list_loaded ? `${s.imported_domains} доменов` : 'не загружен'} />
          <!-- Подпись зависит от протокола: у AWG видно, когда сервер отвечал; у Full — только что
               туннель поднят (tunnelRowText). Цвет — из единого tunnel_health движка. -->
          <StatusRow label="Туннель ({active.name})" tone={s.tunnel_health === 'up' ? 'ok' : 'bad'} value={tunnelRowText(s)} />
          <StatusRow label="DNS" tone={s.dns_up ? 'ok' : 'bad'} value={s.dns_up ? 'работает' : 'нет'} />
          <StatusRow label="Шифрованный DNS" tone={s.doh_up ? 'ok' : 'bad'} value={s.doh_up ? 'работает' : 'нет'} />
          {#if s.wireless_present}
            <StatusRow label="Wi-Fi (SSID)" value={s.ssid || '—'} />
          {/if}
          <StatusRow label="DNS-фильтрация"
                     value={s.dns_provider_desc ? s.dns_provider_desc.name : (s.dns_provider ?? '—')} />
        </StatusList>
      </details>
    </div>

    <!-- Вход — строкой у заголовка раздела, а не блоком внутри него: механика уже правильная
         (действие спрашивает пароль), поэтому хватает одного слова. -->
    <div class="mt-8 flex items-baseline justify-between gap-3 border-b border-border pb-1.5">
      <h3 class="text-xs font-semibold tracking-wider text-muted-foreground uppercase">Управление</h3>
      {#if loggedIn}
        <span class="text-sm text-muted-foreground">Вы вошли как root ·
          <Button variant="link" onclick={doLogout}>выйти</Button></span>
      {:else}
        <span id="login" data-slot="login-gate" class="text-sm text-muted-foreground">Настройки защищены паролем ·
          <Button variant="link" onclick={() => (loginOpen = true)}>Войти</Button></span>
      {/if}
    </div>

    <div class="mt-4 flex flex-col gap-4">
      <div>
        <div class="flex" role="group" aria-label="Режим работы">
          {@render segment('Дома', s.mode !== 'travel', () => s.mode === 'travel' && setMode('home'))}
          {@render segment('В поездке', s.mode === 'travel', () => s.mode !== 'travel' && setMode('travel'))}
        </div>
        <p class="mt-2 text-sm text-muted-foreground">Дома: список сайтов идёт напрямую. В поездке: всё через туннель.</p>
      </div>

      <!-- Свой список — главная настройка продукта, поэтому она здесь, а не в мастере: поменять
           сайт не должно стоить переустановки. Применяется одним DNS-шагом, без разрыва туннеля. -->
      <Field label="Сайты напрямую — ваш список"
             hint="Зона (ru) покрывает все сайты в ней; отдельные — своей строкой. Остальное идёт через туннель.">
        {#if loggedIn && domainsLoaded}
          <Textarea bind:value={userDomainsText} rows="3" disabled={busy}
                    placeholder={'ru\nexample.com'} />
        {:else}
          <Textarea rows="3" disabled
                    placeholder={loggedIn ? 'Загружаю список…' : 'Войдите, чтобы увидеть и изменить список'} />
        {/if}
      </Field>

      <div class="flex flex-wrap gap-3">
        <!-- Без входа кнопка не серая, а ведёт ко входу: серая рядом с активной читается как
             «сломано», а не как «нужен пароль». -->
        <Button class="min-w-35 flex-1" disabled={busy || (loggedIn && !domainsLoaded)}
                onclick={() => (loggedIn ? saveDomains() : (loginOpen = true))}>Сохранить список</Button>
        <Button variant="outline" class="min-w-35 flex-1" disabled={busy} onclick={updateList}>Обновить готовый список</Button>
      </div>
      <p class="text-sm text-muted-foreground">«Обновить готовый список» добавит к вашему community-список популярных сайтов.</p>
      {@render actionNote('manage')}
    </div>

    <div class="mt-8 flex flex-col">
      <!-- Перезапуск и фильтрация — свёрнуты: обе нужны редко, а места занимали пол-экрана между
           главным («работает ли?») и путём «спросить помощь». -->
      <DetailsGroup id="services-group" bind:open={servicesOpen} summary="Сервисы и фильтрация">
        <p class="mb-3 text-sm text-muted-foreground">Перезапуск — первое, что стоит попробовать, если что-то отвалилось.</p>
        <div class="grid grid-cols-3 gap-2">
          <Button variant="outline" size="sm" disabled={busy} onclick={() => restart('vpn', 'туннель')}>Туннель</Button>
          <Button variant="outline" size="sm" disabled={busy} onclick={() => restart('dns', 'DNS')}>DNS</Button>
          <Button variant="outline" size="sm" disabled={busy} onclick={() => restart('doh', 'шифрованный DNS')}>Шифрованный DNS</Button>
        </div>
        {@render actionNote('restart')}

        <Field class="mt-6" label="Блокировка рекламы / взрослого контента"
               hint="«Семейный» блокирует сайты 18+ и форсит безопасный поиск.">
          <NativeSelect bind:value={providerSel} disabled={busy}>
            {#each s.dns_providers ?? [] as p}
              <option value={p.id}>{p.name} — {p.description}</option>
            {/each}
          </NativeSelect>
        </Field>
        <div class="mt-3">
          <Button variant="outline" disabled={busy || !providerSel || providerSel === s.dns_provider} onclick={setProvider}>Применить</Button>
        </div>
        {@render actionNote('dns')}
      </DetailsGroup>

      <!-- Управление туннелем свёрнуто: самый объёмный блок панели, нужен в редкие дни поломки.
           Открывается сам по ссылкам из ответа наверху (tunnelOpen). -->
      <DetailsGroup id="tunnel-group" bind:open={tunnelOpen} summary="Туннель — заменить сервер или сменить протокол">
        <!-- Замена сервера АКТИВНОГО туннеля. Метод, подпись и placeholder — из каталога протоколов. -->
        <SectionTitle id="replace-tunnel">Замена сервера ({active.name})</SectionTitle>
        <p class="mt-2 mb-3 text-sm text-muted-foreground">Вставьте свежий конфиг от своего сервера.
          Не отзовётся — прежний вернётся сам.</p>
        <Field label={active.confLabel}>
          <Textarea bind:value={replaceConf} rows="5" class="font-mono" disabled={busy} placeholder={active.placeholder} />
          <ConfCheck id={active.id} text={replaceConf} />
        </Field>
        {#if active.file}
          <Field class="mt-3" label="…или загрузить файлом">
            <Input type="file" accept=".conf,text/plain" onchange={onReplaceFile} disabled={busy} />
          </Field>
        {/if}
        {#if active.id === 'hysteria2'}{@render speedFields()}{/if}
        <div class="mt-3">
          <Button disabled={busy || replaceConf.trim().length === 0} onclick={replaceTunnel}>
            {replacePhase === 'running' ? 'Применяю…' : 'Заменить конфиг'}
          </Button>
        </div>
        {#if replacePhase === 'running'}
          <p class="mt-3 flex items-center gap-2"><Spinner /> Применяю новый конфиг — при сбое прежний вернётся автоматически.</p>
        {/if}
        {@render actionNote('replace')}
        {#if replaceLog && replacePhase !== 'idle'}
          <details class="mt-3" open={replacePhase === 'fail'}>
            <summary class="cursor-pointer text-sm text-muted-foreground">Журнал замены</summary>
            <LogView text={replaceLog} class="mt-2" />
          </details>
        {/if}

        <!-- Full-тир не установлен: либо кнопка догрузки (железо тянет), либо честное объяснение,
             почему её нет. Молчать нельзя — иначе непонятно, почему функции из документации нет. -->
        {#if !s.full_installed}
          <SectionTitle id="full-tier">Запасные туннели — если этот не выручает</SectionTitle>
          {#if s.full_capable}
            <p class="mt-2 text-sm text-muted-foreground"><strong>VLESS+Reality</strong> — если интернет через VPN
              вообще не открывается. <strong>Hysteria2</strong> — если открывается, но тормозит и рвётся.
              Кнопка скачает общий для них компонент <code class="rounded-sm bg-muted px-1 py-0.5 font-mono">sing-box</code>
              (~11 МБ, на флеше ~42 МБ). Текущий туннель продолжит работать.</p>
            <div class="mt-3">
              <Button disabled={busy || fullPhase === 'running'} onclick={enableFullTier}>
                {fullPhase === 'running' ? 'Устанавливаю…' : 'Установить компонент'}
              </Button>
            </div>
            {#if fullPhase === 'running'}
              <p class="mt-3 flex items-center gap-2"><Spinner /> Скачиваю компонент — это может занять минуту.</p>
            {/if}
            {#if fullLog && fullPhase !== 'idle'}
              <details class="mt-3" open={fullPhase === 'fail'}>
                <summary class="cursor-pointer text-sm text-muted-foreground">Журнал установки</summary>
                <LogView text={fullLog} class="mt-2" />
              </details>
            {/if}
          {:else}
            <p class="mt-2 text-sm text-muted-foreground">Запасные туннели (VLESS+Reality и Hysteria2)
              <strong>на этом роутере недоступны</strong>{#if fullMissing}: {fullMissing}{/if}. Они считаются
              программой, а не ядром — на слабом железе это медленнее самого интернета.</p>
            {#if s.full_missing?.includes('flash')}
              <p class="mt-2 text-sm text-muted-foreground">Место можно освободить (по SSH
                <code class="rounded-sm bg-muted px-1 py-0.5 font-mono">apk del</code> ненужные пакеты) или
                подключить USB-флешку (extroot) — тогда кнопка появится.</p>
            {/if}
          {/if}
        {/if}
        <!-- ЗА пределами {#if !full_installed}: после успешной догрузки блок с кнопкой исчезает, и
             сообщение об успехе исчезло бы вместе с ним — ровно когда его читают. -->
        {@render actionNote('full')}

        <!-- Смена туннеля: СНАЧАЛА выбор направления по симптому (как в мастере), потом одно поле.
             Раньше здесь было по блоку на протокол — три похожих поля подряд на одной странице. -->
        {#if targets.length > 0}
          <SectionTitle id="switch-tunnel">Сменить туннель</SectionTitle>
          <p class="mt-2 text-sm text-muted-foreground">Сейчас активен <strong>{active.name}</strong>. Сайты, DNS и
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
            <Field class="mt-3" label="…или загрузить файлом">
              <Input type="file" accept=".conf,text/plain" onchange={(e) => onSwitchFile(e, switchPick)} disabled={busy} />
            </Field>
          {/if}
          {#if switchPick === 'hysteria2'}{@render speedFields()}{/if}
          <div class="mt-3">
            <Button disabled={busy || (switchConfs[switchPick] ?? '').trim().length === 0} onclick={() => switchTo(pick)}>
              {switchPhase === 'running' && switchTarget === switchPick ? 'Переключаю…' : `Переключиться на ${pick.name}`}
            </Button>
          </div>
          {#if switchPhase === 'running'}
            <p class="mt-3 flex items-center gap-2"><Spinner /> Поднимаю {protocolInfo(switchTarget).name} — при сбое
              вернётся {active.name}.</p>
          {/if}
          {@render actionNote('switch')}
          {#if switchLog && switchPhase !== 'idle'}
            <details class="mt-3" open={switchPhase === 'fail'}>
              <summary class="cursor-pointer text-sm text-muted-foreground">Журнал переключения</summary>
              <LogView text={switchLog} class="mt-2" />
            </details>
          {/if}
        {/if}
      </DetailsGroup>
    </div>

    <!-- Поддержка. Стоит ПЕРЕД опасной зоной и НЕ свёрнута осознанно: человек, у которого не
         работает, должен найти путь «спросить» раньше, чем кнопку «сбросить всё». -->
    <SectionTitle id="support">Если что-то не работает</SectionTitle>
    <p class="mt-3 text-sm text-muted-foreground">Напишите мне в Telegram —
      <a href={SUPPORT.telegramUrl} target="_blank" rel="noreferrer">{SUPPORT.telegram}</a>: отвечаю всем.
      Приложите диагностику — <strong>пароли и ключи вырезаются</strong>, файл вы увидите здесь до отправки.
      Проект и документация — <a href={SUPPORT.page} target="_blank" rel="noreferrer">на GitHub</a>.</p>
    <div class="mt-3 flex flex-wrap gap-3">
      <Button variant="outline" disabled={busy || diagPhase === 'running'} onclick={collectDiagnostics}>
        {diagPhase === 'running' ? 'Собираю…' : 'Собрать диагностику'}
      </Button>
      {#if diagPhase === 'ok'}
        <Button variant="outline" onclick={downloadDiagnostics}>Скачать файл</Button>
      {/if}
    </div>
    {@render actionNote('support')}
    {#if diagPhase === 'ok'}
      <p class="mt-3 text-sm text-muted-foreground">
        {#if diagRemoved.length > 0}
          Вырезано: {diagRemoved.join('; ')}. Адрес сервера оставлен — без него причину не найти.
        {:else}
          Секретов известных форм не нашлось. Всё равно пролистайте текст перед отправкой.
        {/if}
      </p>
      <details open class="mt-2">
        <summary class="cursor-pointer text-sm text-muted-foreground">Что будет отправлено</summary>
        <LogView text={diagText} class="mt-2" />
      </details>
    {/if}

    <div class="mt-8">
      <DetailsGroup id="danger-group" bind:open={dangerOpen} tone="danger" summary="Опасная зона">
        {#if !resetArmed}
          <Button variant="destructive-outline" disabled={busy} onclick={() => (resetArmed = true)}>Сбросить настройку cheburnet…</Button>
        {:else}
          <!-- Честно перечисляем и то, что останется: «сбросить всё» читают как «удалить
               программу», а это не так. Списками, а не прозой: два перечня сравниваются взглядом. -->
          <p class="text-destructive">Роутер вернётся к обычной маршрутизации — весь трафик пойдёт напрямую, без VPN.</p>
          <ul class="mt-2 list-disc pl-5 text-sm">
            <li><strong>Снимется:</strong> туннель, разделение трафика, шифрованный DNS, фильтрация.</li>
            <li><strong>Останется:</strong> программа и эта панель, Wi-Fi, пароль роутера.</li>
          </ul>
          <p class="mt-2 text-sm text-muted-foreground">Настроить заново можно сразу отсюда. Удалить полностью —
            <code class="rounded-sm bg-muted px-1 py-0.5 font-mono">apk del cheburnet</code> по SSH.</p>
          <Field class="mt-3" label="Введите слово RESET для подтверждения">
            <Input type="text" bind:value={resetWord} placeholder="RESET" />
          </Field>
          <div class="mt-3 flex flex-wrap gap-3">
            <Button variant="outline" class="min-w-35 flex-1" disabled={busy}
                    onclick={() => { resetArmed = false; resetWord = ''; }}>Отмена</Button>
            <Button variant="destructive" class="min-w-35 flex-1" disabled={busy || !resetOk} onclick={factoryReset}>
              Подтвердить сброс
            </Button>
          </div>
        {/if}
        {#if resetPhase === 'running'}
          <p class="mt-3 flex items-center gap-2"><Spinner /> Снимаю конфигурацию — роутер на несколько секунд
            перезапустит сеть.</p>
        {/if}
        {@render actionNote('danger')}
        <!-- Путь назад в мастер: ссылка несёт свежий токен, выпущенный сбросом (reset.uc). Токена
             нет — честно показываем путь через SSH, а не битую ссылку. -->
        {#if resetPhase === 'ok'}
          {#if resetToken}
            <p class="mt-3 font-semibold text-success">Можно настраивать заново:
              <a href="?token={encodeURIComponent(resetToken)}">открыть мастер настройки</a>.</p>
          {:else}
            <p class="mt-3 text-sm text-muted-foreground">Чтобы настроить заново, запустите команду установки по SSH —
              она напечатает новую ссылку на мастер.</p>
          {/if}
        {/if}
      </DetailsGroup>
    </div>
  {:else}
    <p class="mt-4 text-muted-foreground">Загрузка…</p>
  {/if}

  <div class="mt-8">
    <Button variant="outline" onclick={reinstall}>Настроить заново</Button>
    <!-- Подпись обязательна: кнопка стоит сразу под «Опасной зоной» и без неё читается как второй
         способ всё стереть. -->
    <p class="mt-2 text-sm text-muted-foreground">Пройти мастер заново. Текущая настройка работает до конца установки.</p>
  </div>
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
