<script>
  import Spinner from '$lib/components/ui/spinner/spinner.svelte';
  // Список проверок (preflight) и чеклист установки: один компонент на оба — у них одна форма
  // строки (значок + текст + подсказка) и общий язык значков.
  // items: [{ mark: 'ok'|'soft'|'bad'|'pending'|'running', text, fix? }]
  let { items } = $props();
  const MARK = { ok: '✓', soft: '!', bad: '✗', pending: '·' };
  const TONE = { ok: 'text-success', soft: 'font-bold text-warning', bad: 'text-destructive', pending: 'text-muted-foreground' };
</script>

<ul class="my-2 flex flex-col">
  {#each items as it}
    <li class="flex items-center gap-2.5 border-b border-border py-2 text-sm {it.mark === 'pending' ? 'text-muted-foreground' : ''}">
      <span class="flex w-4 shrink-0 justify-center {TONE[it.mark] ?? ''}">
        {#if it.mark === 'running'}<Spinner class="size-3.5" />{:else}{MARK[it.mark]}{/if}
      </span>
      <span>{it.text}</span>
      {#if it.fix}<span class="text-sm text-muted-foreground">→ {it.fix}</span>{/if}
    </li>
  {/each}
</ul>
