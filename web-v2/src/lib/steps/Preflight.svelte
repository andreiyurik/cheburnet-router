<script>
  import { cheburnet } from '../ubus.js';
  import { softRisks, canOverride, fullReasons } from '../logic.js';

  // onReady(fullCapable, acceptRisk, fullWhyNot) — вызвать, когда можно идти дальше. fullCapable = tiers.full
  // (железо ПОТЯНЕТ Full: AES-arch + RAM/флеш + sing-box ставится по apk --simulate), НЕ
  // full_installed: мастер предлагает выбор AmneziaWG / VLESS+Reality уже на подходящем железе, а
  // sing-box догружается автоматически при выборе Reality (ADR 0004). Не тянет → только AmneziaWG.
  // acceptRisk=true — пользователь осознанно идёт дальше с непройденными soft-проверками железа
  // (мало флеша/RAM); Setup донесёт это до install как accept_risk. fullWhyNot — причины, по которым
  // Reality недоступен: мастер показывает их вместо безликого «недоступно».
  let { onReady } = $props();

  let report = $state(null);
  let error = $state('');
  let loading = $state(true);
  // Согласие на риск — намеренно отдельный чекбокс: красная кнопка не должна быть кликабельна
  // одним движением, иначе она станет обычным путём вместо исключения.
  let riskAccepted = $state(false);

  const risks = $derived(softRisks(report));
  const overridable = $derived(canOverride(report));

  async function run() {
    loading = true;
    error = '';
    report = null;
    riskAccepted = false;
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
        <li class:ok={c.ok} class:bad={!c.ok && c.severity !== 'soft'} class:soft={!c.ok && c.severity === 'soft'}>
          <span class="mark">{c.ok ? '✓' : (c.severity === 'soft' ? '!' : '✗')}</span>
          <span class="detail">{c.detail}</span>
          {#if !c.ok && c.fix}<span class="fix">→ {c.fix}</span>{/if}
        </li>
      {/each}
    </ul>

    {#if report.passed}
      <p class="ok-msg">Роутер подходит — все {report.total} проверок пройдены.</p>
      <button class="primary" onclick={() => onReady(report.tiers?.full === true, false, fullReasons(report))}>Продолжить</button>
    {:else if overridable}
      <!-- Все провалы — «железо впритык»: установка возможна, но с оговорками. Сначала честно
           объясняем каждый пункт и что можно сделать вместо риска, только потом красная кнопка. -->
      <p class="warn">Роутер слабее рекомендуемого. Ничего на роутере не менялось.</p>
      <p>
        Строки с «!» выше — это не «нельзя», а «впритык». Что это значит и как поправить,
        если хочется наверняка:
      </p>

      {#each risks as r}
        <div class="risk-item">
          <h3>{r.title}</h3>
          <p class="small">{r.risk}</p>
          {#if r.fixes.length > 0}
            <ul class="small">
              {#each r.fixes as fix}<li>{fix}</li>{/each}
            </ul>
          {/if}
        </div>
      {/each}

      <p class="note">
        Исправили — нажмите «Перепроверить». Не хотите ничего менять — можно установить как есть:
        роутер обычно работает, но <strong>мы не гарантируем стабильность</strong>. Если что-то
        пойдёт не так, установка сама вернёт роутер в исходное состояние.
      </p>

      <label class="risk-accept">
        <input type="checkbox" bind:checked={riskAccepted} />
        Я понимаю: роутер слабее требуемого, стабильность не гарантируется, продолжаю на свой
        страх и риск.
      </label>

      <!-- Рискованное действие — отдельной большой кнопкой ВНИЗУ, а не рядом с безопасной:
           случайный клик мимо «Перепроверить» не должен запускать установку. -->
      <div class="row">
        <button onclick={run}>Перепроверить</button>
      </div>
      <button class="danger wide" disabled={!riskAccepted}
              onclick={() => onReady(report.tiers?.full === true, true, fullReasons(report))}>
        Всё равно установить
      </button>
    {:else}
      <p class="warn">Пока установить нельзя: не пройдено {report.failed} из {report.total} проверок.
        Ничего на роутере не менялось. Строки с ✗ выше показывают, что именно не так и как это
        исправить{#if report.soft_failed > 0} (строки с «!» — железо впритык, их можно пережить,
        а вот ✗ обязательны: без этого нужные пакеты просто не установятся){/if}, — после
        исправления нажмите «Перепроверить».</p>
      <button onclick={run}>Перепроверить</button>
    {/if}
  {/if}
</section>
