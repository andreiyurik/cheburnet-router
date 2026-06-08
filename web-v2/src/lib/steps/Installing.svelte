<script>
  import { onDestroy } from 'svelte';
  import { cheburnet } from '../ubus.js';

  // args — { awg_conf, domains, token } для метода install.
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

  onDestroy(stop);
  start();
</script>

<section>
  <h2>Установка</h2>

  {#if phase === 'starting'}
    <p class="muted">Запускаю…</p>
  {:else if phase === 'running'}
    <p><span class="spinner"></span> Шаг: <strong>{step || '…'}</strong></p>
  {:else if phase === 'ok'}
    <p class="ok-msg">✓ Готово. Открываю панель…</p>
  {:else if phase === 'fail'}
    <p class="warn">✗ {error}</p>
    <button onclick={onRetry}>Изменить данные и повторить</button>
  {/if}

  {#if log}
    <details open={phase === 'fail'}>
      <summary>Журнал</summary>
      <pre class="log">{log}</pre>
    </details>
  {/if}
</section>
