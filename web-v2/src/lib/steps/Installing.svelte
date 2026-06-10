<script>
  import { onDestroy } from 'svelte';
  import { cheburnet } from '../ubus.js';

  // args — { awg_conf, root_password, [ssid, wifi_key], domains, token } для метода install.
  // onDone — установка завершилась успешно. onRetry — вернуться на Setup при ошибке.
  let { args, onDone, onRetry } = $props();

  let phase = $state('starting'); // starting | running | ok | fail
  let step = $state('');
  let log = $state('');
  let error = $state('');
  let timer = null;

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
          error = 'установка отменена — изменения откатаны';
        } else {
          phase = 'fail';
          error = p.result === 'crashed' ? 'установщик аварийно завершился' : 'установка не удалась';
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
  async function copyLog() {
    try {
      await navigator.clipboard.writeText(log);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      // clipboard может быть недоступен (http-origin) — журнал виден ниже, скопируют руками
    }
  }

  onDestroy(stop);
  start();
</script>

<section>
  <h2>Установка</h2>

  {#if phase === 'starting'}
    <p class="muted">Запускаю…</p>
  {:else if phase === 'running'}
    <p><span class="spinner"></span> Шаг: <strong>{step || '…'}</strong></p>
    <button disabled={cancelling} onclick={cancel}>
      {cancelling ? 'Отменяю…' : 'Отменить установку'}
    </button>
  {:else if phase === 'ok'}
    <p class="ok-msg">✓ Готово. Открываю панель…</p>
  {:else if phase === 'fail'}
    <p class="warn">✗ {error}</p>
    <div class="support">
      <strong>Что делать</strong>
      <ol>
        <li>Изменения откатаны — роутер в исходном состоянии, можно пробовать снова.</li>
        <li>Частые причины: опечатка в AWG-конфиге (вставлен не целиком), нет интернета на
          WAN, недоступен сервер VPN-провайдера.</li>
        <li>Не получается — скопируйте журнал ниже и приложите его к вопросу в сообществе
          проекта.</li>
      </ol>
    </div>
    <div class="row">
      <button onclick={onRetry}>Изменить данные и повторить</button>
      {#if log}
        <button onclick={copyLog}>{copied ? '✓ Скопировано' : 'Копировать журнал'}</button>
      {/if}
    </div>
  {/if}

  {#if log}
    <details open={phase === 'fail'}>
      <summary>Журнал</summary>
      <pre class="log">{log}</pre>
    </details>
  {/if}
</section>
