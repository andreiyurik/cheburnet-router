<script>
  // Строка сводки: слева подпись (может нести ссылку), справа значение. tone красит значение.
  let { tone = 'default', value = '', label, children } = $props();
  const TONE = { ok: 'text-success', bad: 'text-destructive', default: '' };
</script>

<li class="flex items-baseline justify-between gap-3 border-b border-border py-2.5">
  <span class="text-sm text-muted-foreground">{#if label}{label}{/if}{@render children?.()}</span>
  <strong class="text-right text-base {TONE[tone]}">{value}</strong>
</li>
