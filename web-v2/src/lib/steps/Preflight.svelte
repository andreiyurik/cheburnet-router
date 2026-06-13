<script>
  import { cheburnet } from '../ubus.js';

  // onReady(fullAvailable) — вызвать, когда железо подходит; fullAvailable = тянет ли роутер
  // Full-тир (VLESS+Reality), из report.tiers.full (preflight). Определяет, предлагать ли его в Setup.
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
  <h2>Проверка железа</h2>
  <p class="muted">Гейткипер честно скажет, потянет ли роутер стек — до любых изменений.</p>

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
      <p class="ok-msg">Железо подходит ({report.total} проверок).</p>
      {#if report.tiers?.full}
        <p class="muted">Доступен Full-тир: VLESS+Reality (sing-box) — для сетей с жёстким DPI.</p>
      {:else if report.tiers}
        <p class="muted">Full-тир (VLESS+Reality) недоступен на этом железе — будет AmneziaWG (этого хватает большинству).</p>
      {/if}
      <button class="primary" onclick={() => onReady(report.tiers?.full === true)}>Продолжить</button>
    {:else}
      <p class="warn">Провалено {report.failed} из {report.total}. Устраните указанное и повторите.</p>
      <button onclick={run}>Перепроверить</button>
    {/if}
  {/if}
</section>
