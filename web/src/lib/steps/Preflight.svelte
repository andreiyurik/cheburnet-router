<script>
  import { cheburnet } from '../ubus.js';
  import { softRisks, canOverride, fullReasons } from '../logic.js';
  import * as Card from '$lib/components/ui/card/index.js';
  import Button from '$lib/components/ui/button/button.svelte';
  import * as Alert from '$lib/components/ui/alert/index.js';
  import Checkbox from '$lib/components/ui/checkbox/checkbox.svelte';
  import CheckList from '$lib/components/CheckList.svelte';
  import StatusIcon from '$lib/components/StatusIcon.svelte';

  // onReady(fullCapable, acceptRisk, fullWhyNot): fullCapable = tiers.full (железо ПОТЯНЕТ Full, не
  // full_installed — бинарь догрузится при выборе Full-протокола, ADR 0004); acceptRisk — soft-провалы
  // приняты осознанно (Setup несёт в install); fullWhyNot — причины, почему Full недоступен.
  let { onReady } = $props();

  let report = $state(null);
  let error = $state('');
  let loading = $state(true);
  // Согласие на риск — намеренно отдельный чекбокс: красная кнопка не должна быть кликабельна
  // одним движением, иначе она станет обычным путём вместо исключения.
  let riskAccepted = $state(false);

  const risks = $derived(softRisks(report));
  const overridable = $derived(canOverride(report));
  const checkItems = $derived(
    (report?.checks ?? []).map((c) => ({
      mark: c.ok ? 'ok' : c.severity === 'soft' ? 'soft' : 'bad',
      text: c.detail,
      fix: c.ok ? '' : c.fix,
    }))
  );

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

<Card.Root>
  <Card.Header>
    <Card.Title>Проверка роутера</Card.Title>
    <Card.Description>Сначала убедимся, что роутер подходит, — до любых изменений на нём.</Card.Description>
  </Card.Header>

  <Card.Content>
    {#if loading}
      <p class="text-muted-foreground">Проверяю…</p>
    {:else if error}
      <p class="text-destructive">Не удалось выполнить проверку: {error}</p>
      <Button variant="outline" onclick={run}>Повторить</Button>
    {:else if report}
      <CheckList items={checkItems} />

      <!-- Легенда — рядом со списком, а не внутри текста ошибки: значки видны всегда, а объяснение
           раньше появлялось только в одной из веток отказа. -->
      {#if !report.passed}
        <p class="text-sm text-muted-foreground">
          <span class="font-bold text-destructive">✗</span> обязательное — без этого пакеты не
          установятся. <span class="font-bold text-warning">!</span> железо впритык — можно пережить.
        </p>
      {/if}

      {#if report.passed}
        <div>
          <p class="font-display text-2xl">Роутер подходит</p>
          <p class="text-muted-foreground">Все {report.total} проверок пройдены.</p>
        </div>
        <Button size="lg" onclick={() => onReady(report.tiers?.full === true, false, fullReasons(report))}>
          Продолжить
        </Button>
      {:else if overridable}
        <!-- Все провалы — «железо впритык»: установка возможна, но с оговорками. Сначала честно
             объясняем каждый пункт и что можно сделать вместо риска, только потом красная кнопка. -->
        <div>
          <p class="font-display text-2xl text-warning">Роутер слабее рекомендуемого</p>
          <p class="text-muted-foreground">Ничего на роутере не менялось.</p>
        </div>
        <p>
          Строки с «!» выше — это не «нельзя», а «впритык». Что это значит и как поправить,
          если хочется наверняка:
        </p>

        {#each risks as r}
          <div class="border-l-[3px] border-warning pl-3">
            <h3 class="font-semibold">{r.title}</h3>
            <p class="mt-1 text-sm">{r.risk}</p>
            {#if r.fixes.length > 0}
              <ul class="mt-1 list-disc pl-5 text-sm text-muted-foreground">
                {#each r.fixes as fix}<li>{fix}</li>{/each}
              </ul>
            {/if}
          </div>
        {/each}

        <p class="text-muted-foreground">Исправили — нажмите «Перепроверить». Не хотите ничего менять —
          можно установить как есть: роутер обычно работает, но стабильность не гарантируется. При сбое
          установка сама вернёт роутер в исходное состояние.</p>

        <label class="flex cursor-pointer items-start gap-3 text-sm">
          <Checkbox bind:checked={riskAccepted} class="mt-0.5" />
          <span>Я понимаю: роутер слабее требуемого, стабильность не гарантируется, продолжаю на свой
            страх и риск.</span>
        </label>

        <!-- Рискованное действие — отдельной большой кнопкой ВНИЗУ, а не рядом с безопасной:
             случайный клик мимо «Перепроверить» не должен запускать установку. -->
        <Button variant="outline" class="w-full" onclick={run}>Перепроверить</Button>
        <Button variant="destructive" size="lg" class="w-full" disabled={!riskAccepted}
                onclick={() => onReady(report.tiers?.full === true, true, fullReasons(report))}>
          Всё равно установить
        </Button>
      {:else}
        <div>
          <p class="font-display text-2xl text-destructive">Пока установить нельзя</p>
          <p class="text-muted-foreground">Не пройдено {report.failed} из {report.total} проверок.
            Ничего на роутере не менялось.</p>
        </div>
        <p>Строки с ✗ выше показывают, что не так и как это исправить. Исправили — нажмите
          «Перепроверить».</p>
        <Button variant="outline" onclick={run}>Перепроверить</Button>
      {/if}
    {/if}
  </Card.Content>
</Card.Root>
