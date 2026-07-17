<script>
  import { onDestroy } from 'svelte';
  import mascot from '../../assets/cheburashka.png';
  import { cheburnet } from '../ubus.js';

  // args — { awg_conf, root_password, [ssid, wifi_key], domains, token } для метода install.
  // onDone — установка завершилась успешно. onRetry — вернуться на Setup при ошибке.
  let { args, onDone, onRetry } = $props();

  let phase = $state('starting'); // starting | running | ok | fail
  let step = $state('');
  let log = $state('');
  let logEl = $state(null); // <pre> живого лога — прокручиваем к свежим строкам

  // При обновлении лога держим прокрутку внизу (свежие строки видны без ручного скролла).
  $effect(() => {
    log; // зависимость
    if (logEl) logEl.scrollTop = logEl.scrollHeight;
  });

  // Понятные подписи технических шагов движка (STATE_FILE) — что именно идёт сейчас.
  const STEP_LABELS = {
    starting: 'Запуск…',
    preflight: 'Проверка роутера',
    'singbox-download': 'Загрузка компонента VLESS+Reality (~15 МБ)',
    snapshot: 'Сохранение точки отката',
    vpn: 'Настройка VPN-туннеля',
    singbox: 'Настройка VPN-туннеля',
    dns: 'Настройка DNS и split-routing',
    doh: 'Шифрованный DNS',
    wifi: 'Настройка Wi-Fi',
    firewall: 'Firewall и kill-switch',
    'health-check': 'Проверка связи (поднятие туннеля, до ~30 сек)',
  };
  const stepLabel = $derived(STEP_LABELS[step] ?? step ?? '…');
  let error = $state('');
  let advice = $state(null); // { title, items[] } — адресная диагностика по reason
  let timer = null;

  // Адресная диагностика по машинному коду исхода (install_progress.reason).
  // Главный кейс: health — роутер настроен ПРАВИЛЬНО, но VPN-сервер не ответил. Без этого
  // человек с протухшей подпиской дёргает Wi-Fi и пароли вместо конфига.
  function explainFail(reason) {
    if (reason === 'health') {
      error = 'VPN-сервер не ответил — туннель не поднялся.';
      advice = {
        title: 'Роутер настроен правильно, но сервер из вашего VPN-конфига молчит. Изменения откатаны. Чаще всего это значит:',
        items: [
          'подписка у VPN-провайдера закончилась или сервер отключён — проверьте личный кабинет;',
          'конфиг устарел — скачайте свежий файл .conf и загрузите его заново;',
          'провайдер интернета мешает VPN-протоколу — попробуйте конфиг с другим сервером.',
        ],
        action: 'Загрузить другой конфиг',
      };
      return;
    }
    if (reason === 'step:vpn') {
      error = 'VPN-конфиг не принят.';
      advice = {
        title: 'Изменения откатаны. Проверьте файл конфига:',
        items: [
          'он вставлен целиком — от строки [Interface] до конца;',
          'это конфиг AmneziaWG/WireGuard «для роутеров» (.conf), а не ссылка или QR-код.',
        ],
        action: 'Исправить конфиг',
      };
      return;
    }
    if (reason && reason.startsWith('step:')) {
      const s = reason.slice(5);
      error = `Сбой на этапе «${STEP_LABELS[s] ?? s}».`;
      advice = {
        title: 'Изменения откатаны — роутер в исходном состоянии. Что можно сделать:',
        items: [
          'попробуйте ещё раз — разовые сбои случаются;',
          'если повторяется — скопируйте журнал ниже и приложите его к вопросу в сообществе проекта.',
        ],
        action: 'Попробовать снова',
      };
      return;
    }
    if (reason === 'singbox-download') {
      error = 'Не удалось загрузить компонент sing-box.';
      advice = {
        title: 'Изменений на роутере нет. Для VLESS+Reality нужно скачать компонент sing-box (~15 МБ) с серверов OpenWrt:',
        items: [
          'проверьте, что роутер подключён к интернету (кабель WAN на месте);',
          'иногда загрузка рвётся из-за сети провайдера — просто попробуйте ещё раз;',
          'либо вернитесь и выберите AmneziaWG — он не требует догрузки.',
        ],
        action: 'Попробовать снова',
      };
      return;
    }
    if (reason === 'preflight') {
      error = 'Роутер не прошёл проверку.';
      advice = {
        title: 'Изменений нет. Вернитесь назад — с экрана настройки кнопка «Назад» запустит проверку заново и покажет, что именно не так.',
        items: [],
        action: 'Назад к настройке',
      };
      return;
    }
    // Код не пришёл (старый пакет / crash) — прежний общий текст.
    advice = {
      title: 'Что делать',
      items: [
        'Изменения откатаны — роутер в исходном состоянии, можно пробовать снова.',
        'Частые причины: опечатка в AWG-конфиге (вставлен не целиком), нет интернета на WAN, недоступен сервер VPN-провайдера.',
        'Не получается — скопируйте журнал ниже и приложите его к вопросу в сообществе проекта.',
      ],
      action: 'Изменить данные и повторить',
    };
  }

  // Движок ставит долго (apk + шаги) — install лишь запускает фон и возвращает {started};
  // прогресс тянем поллингом install_progress (см. engine/ubus: фон+poll).
  async function start() {
    try {
      await cheburnet('install', args);
      phase = 'running';
      poll();
      timer = setInterval(poll, 2000);
    } catch (e) {
      error = e.message;
      phase = 'fail';
    }
  }

  async function poll() {
    try {
      const p = await cheburnet('install_progress');
      step = p.step ?? '';
      log = p.log ?? '';
      if (p.done) {
        stop();
        if (p.result === 'ok') {
          phase = 'ok';
          // короткая пауза, чтобы пользователь увидел «готово», затем — панель
          setTimeout(onDone, 800);
        } else if (p.result === 'cancelled') {
          phase = 'fail';
          error = 'Установка отменена — изменения откатаны.';
          advice = null;
        } else if (p.result === 'crashed') {
          phase = 'fail';
          error = 'Установщик аварийно завершился.';
          explainFail(null);
        } else {
          phase = 'fail';
          error = 'Установка не удалась.';
          explainFail(p.reason ?? null);
        }
      }
    } catch (e) {
      // единичный сбой поллинга не валим — следующий тик повторит
      step = `(ошибка опроса: ${e.message})`;
    }
  }

  function stop() {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  }

  // Отмена: kill фоновой установки + откат снимка (движок). Токен — тот же, что у install.
  async function cancel() {
    if (!confirm('Прервать установку? Уже применённые шаги будут откатаны.')) return;
    cancelling = true;
    try {
      await cheburnet('install_cancel', { token: args.token });
      // дальнейшее покажет обычный поллинг (done + result=cancelled)
    } catch (e) {
      step = `(не удалось отменить: ${e.message})`;
      cancelling = false;
    }
  }

  let cancelling = $state(false);
  let copied = $state(false);

  // Копировать журнал: главное, что нужно приложить к вопросу о сбое.
  // ВАЖНО: navigator.clipboard работает только на https, а мастер живёт на http://192.168.1.1 —
  // поэтому основной путь здесь fallback через скрытый textarea + execCommand (работает на http).
  async function copyLog() {
    let done = false;
    try {
      await navigator.clipboard.writeText(log);
      done = true;
    } catch {
      const ta = document.createElement('textarea');
      ta.value = log;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { done = document.execCommand('copy'); } catch { /* совсем без клипборда — есть «Скачать» */ }
      ta.remove();
    }
    if (done) {
      copied = true;
      setTimeout(() => (copied = false), 2000);
    }
  }

  // Скачать журнал файлом — надёжный путь передать лог (Blob-download работает и на http).
  function downloadLog() {
    const blob = new Blob([log], { type: 'text/plain' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'cheburnet-журнал.txt';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  onDestroy(stop);
  start();
</script>

<section>
  <h2>Установка</h2>

  {#if phase === 'starting'}
    <p class="muted">Запускаю…</p>
  {:else if phase === 'running'}
    <p><span class="spinner"></span> <strong>{stepLabel}</strong></p>
    <p class="note">
      📶 Пока идёт настройка, интернет и Wi-Fi ненадолго пропадут — это нормально.
      <strong>Не вынимайте кабель и не выключайте роутер.</strong>
      {#if step === 'health-check'}
        Сейчас самый долгий шаг — проверка связи через туннель (до полминуты). Просто подождите:
        если сервер не ответит, роутер сам всё вернёт назад.
      {:else}
        Связь восстановится сама — даже если что-то пойдёт не так.
      {/if}
    </p>
    <p class="muted small">Настройка занимает 1–3 минуты — не закрывайте страницу.</p>
    {#if log}
      <pre class="log live" bind:this={logEl}>{log}</pre>
    {/if}
    <button disabled={cancelling} onclick={cancel}>
      {cancelling ? 'Отменяю…' : 'Отменить установку'}
    </button>
  {:else if phase === 'ok'}
    <div class="done">
      <img src={mascot} alt="" width="84" height="84" />
      <p class="ok-msg">Готово! Роутер настроен. Открываю панель…</p>
    </div>
  {:else if phase === 'fail'}
    <p class="warn">✗ {error}</p>
    {#if advice}
      <div class="support">
        <strong>{advice.title}</strong>
        {#if advice.items.length > 0}
          <ol>
            {#each advice.items as item}<li>{item}</li>{/each}
          </ol>
        {/if}
      </div>
    {/if}
    <div class="row">
      <button class="primary" onclick={onRetry}>{advice?.action ?? 'Изменить данные и повторить'}</button>
      {#if log}
        <button onclick={copyLog}>{copied ? '✓ Скопировано' : 'Копировать журнал'}</button>
        <button onclick={downloadLog}>Скачать журнал</button>
      {/if}
    </div>
  {/if}

  {#if log && phase !== 'running'}
    <details open={phase === 'fail'}>
      <summary>Журнал</summary>
      <pre class="log">{log}</pre>
    </details>
  {/if}
</section>
