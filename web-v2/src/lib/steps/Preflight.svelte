<script>
  import { cheburnet } from '../ubus.js';

  // onReady(fullAvailable) — вызвать, когда железо подходит. fullAvailable (report.tiers.full)
  // сейчас игнорируется App'ом: Full-тир де-скоупнут на v2.1, текст о тирах тут не показываем.
  let { onReady } = $props();

  let report = $state(null);
  let error = $state('');
  let loading = $state(true);

  async function run() {
    loading = true;
    error = '';
    report = null;
    try {
      report = await cheburnet('preflight');
    } catch (e) {
      error = e.message;
    } finally {
      loading = false;
    }
  }

  run();
</script>

<section>
  <h2>Проверка роутера</h2>
  <p class="muted">Сначала убедимся, что роутер подходит, — до любых изменений на нём.</p>

  {#if loading}
    <p class="muted">Проверяю…</p>
  {:else if error}
    <p class="warn">Не удалось выполнить проверку: {error}</p>
    <button onclick={run}>Повторить</button>
  {:else if report}
    <ul class="checks">
      {#each report.checks as c}
        <li class:ok={c.ok} class:bad={!c.ok}>
          <span class="mark">{c.ok ? '✓' : '✗'}</span>
          <span class="detail">{c.detail}</span>
          {#if !c.ok && c.fix}<span class="fix">→ {c.fix}</span>{/if}
        </li>
      {/each}
    </ul>

    {#if report.passed}
      <p class="ok-msg">Роутер подходит — все {report.total} проверок пройдены.</p>
      <button class="primary" onclick={() => onReady(report.tiers?.full === true)}>Продолжить</button>
    {:else}
      <p class="warn">Пока установить нельзя: не пройдено {report.failed} из {report.total} проверок.
        Ничего на роутере не менялось. Строки с ✗ выше показывают, что именно не так и как это
        исправить, — после исправления нажмите «Перепроверить».</p>
      <button onclick={run}>Перепроверить</button>
    {/if}
  {/if}
</section>
