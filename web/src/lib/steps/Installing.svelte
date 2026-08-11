<script>
  import { onDestroy } from 'svelte';
  import mascot from '../../assets/cheburashka.png';
  import { cheburnet } from '../ubus.js';
  import { STEP_LABELS, installPlan, explainFail, SUPPORT } from '../logic.js';
  import Card from '../ui/Card.svelte';
  import Button from '../ui/Button.svelte';

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

  const stepLabel = $derived(STEP_LABELS[step] ?? step ?? '…');
  // Чеклист шагов: видно, сколько пройдено и сколько осталось, — одна меняющаяся строка на
  // 1–3 минуты без интернета читалась как «зависло».
  const plan = installPlan(args);
  const planIdx = $derived(plan.findIndex((p) => p.id === step));
  // Подряд неудачные опросы прогресса = страница потеряла роутер (обычно включился новый Wi-Fi
  // и устройство ушло из сети роутера). Это штатно — объясняем, как вернуться, и продолжаем поллить.
  let pollFails = $state(0);
  const lostContact = $derived(pollFails >= 4);
  let error = $state('');
  let advice = $state(null); // { title, items[] } — адресная диагностика по reason
  let timer = null;

  // Адресная диагностика — чистая explainFail (logic.js, под vitest). error=null у
  // генерик-ветки → оставляем текст, выставленный вызывающим («не удалась» / «аварийно»).
  function applyFail(reason) {
    const ex = explainFail(reason);
    if (ex.error) error = ex.error;
    advice = ex.advice;
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
      pollFails = 0;
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
          applyFail(null);
        } else {
          phase = 'fail';
          error = 'Установка не удалась.';
          applyFail(p.reason ?? null);
        }
      }
    } catch {
      // сбой поллинга не валим — следующий тик повторит; после нескольких подряд
      // покажется подсказка «страница потеряла роутер» (lostContact)
      pollFails += 1;
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
  let logExpanded = $state(false); // живая консоль: полоска 180px ↔ полная высота
  // Кнопка разворачивания появляется, только когда лог реально не влезает в полоску
  // (~9 строк на 180px) — на коротком логе она обещала бы то, чего нет.
  const logOverflows = $derived(log.split('\n').length > 9);

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

<Card title="Установка">
  {#if phase === 'starting'}
    <p class="muted">Запускаю…</p>
  {:else if phase === 'running'}
    {#if planIdx >= 0}
      <ul class="checks">
        {#each plan as p, i}
          <li class:ok={i < planIdx} class:pending={i > planIdx}>
            <span class="mark">{#if i < planIdx}✓{:else if i === planIdx}<span class="spinner"></span>{:else}·{/if}</span>
            <span>{p.label}</span>
          </li>
        {/each}
      </ul>
    {:else}
      <p><span class="spinner"></span> <strong>{stepLabel}</strong></p>
    {/if}
    {#if lostContact}
      <p class="note"><strong>Страница потеряла связь с роутером — это ожидаемо</strong>, когда
        включается новая сеть. Установка продолжается на самом роутере.
        {#if args.ssid}Подключитесь к Wi-Fi «{args.ssid}» и вернитесь сюда — страница
        подхватит прогресс сама.{:else}Переподключитесь к сети роутера (кабель или Wi-Fi) —
        страница подхватит прогресс сама.{/if}</p>
    {/if}
    <p class="note">
      Интернет и Wi-Fi сейчас пропадут — это нормально. <strong>Не выключайте роутер и не
      закрывайте страницу.</strong>
      {#if step === 'health-check'}
        Идёт самый долгий шаг — проверка связи через туннель, до полминуты. Если сервер не
        ответит, роутер сам всё вернёт назад.
      {/if}
    </p>
    {#if log}
      <pre class="log live" class:expanded={logExpanded} bind:this={logEl}>{log}</pre>
      {#if logOverflows || logExpanded}
        <p class="small"><Button variant="link" type="button" onclick={() => (logExpanded = !logExpanded)}>
          {logExpanded ? 'Свернуть журнал' : 'Развернуть журнал'}
        </Button></p>
      {/if}
    {/if}
    <Button disabled={cancelling} onclick={cancel}>
      {cancelling ? 'Отменяю…' : 'Отменить установку'}
    </Button>
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
      <Button variant="primary" onclick={onRetry}>{advice?.action ?? 'Изменить данные и повторить'}</Button>
      {#if log}
        <Button onclick={copyLog}>{copied ? '✓ Скопировано' : 'Копировать журнал'}</Button>
        <Button onclick={downloadLog}>Скачать журнал</Button>
      {/if}
    </div>
    <!-- Куда писать — именно здесь: это единственный экран, где человек уже упёрся и ещё не ушёл.
         Полной диагностики тут нет намеренно: она admin-метод, а пароль root на этом шаге ещё не
         применён — сессии нет. Журнал установки при этом уже содержит всё нужное. -->
    <p class="muted small">Не получается разобраться — напишите мне в Telegram
      <a href={SUPPORT.telegramUrl} target="_blank" rel="noreferrer">{SUPPORT.telegram}</a> и
      приложите журнал (кнопка выше). Когда роутер настроится, в панели появится кнопка
      «Собрать диагностику» — она вырезает пароли и ключи автоматически.</p>
  {/if}

  {#if log && phase !== 'running'}
    <details open={phase === 'fail'}>
      <summary>Журнал</summary>
      <pre class="log">{log}</pre>
    </details>
  {/if}
</Card>
