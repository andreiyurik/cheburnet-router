<script>
  // Значок для плашек состояния: галочка / восклицание / крест. Инлайновый SVG — иконочная
  // библиотека ради трёх фигур не нужна. tone красит его из токенов темы.
  let { tone = 'ok', class: className = '' } = $props();
  const TONE = { ok: 'text-success', warn: 'text-warning', bad: 'text-destructive' };
</script>

<svg
  class="{TONE[tone]} {className}"
  viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
  stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"
>
  <circle cx="12" cy="12" r="9" />
  {#if tone === 'ok'}
    <path d="m8.5 12.2 2.4 2.4 4.6-4.9" />
  {:else if tone === 'warn'}
    <path d="M12 7.5v5" /><path d="M12 16.3v.2" />
  {:else}
    <path d="m9 9 6 6" /><path d="m15 9-6 6" />
  {/if}
</svg>
