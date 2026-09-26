<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), value = $bindable(), class: className, ...restProps } = $props();
  // Моноширинный шрифт НЕ в базе: он уместен в конфиге (class="font-mono"), но список
  // доменов и подсказки им выглядят как консоль — для адресата это лишний барьер.
  // Квирк iOS: шрифт < 16px на фокусе зумит страницу — подробнее в input.svelte.
  const base = 'flex w-full rounded-md border border-input bg-background px-3 py-2 '
    + 'text-base transition-colors outline-none resize-y placeholder:text-muted-foreground '
    + 'hover:border-muted-foreground focus-visible:border-ring '
    + 'aria-invalid:border-destructive disabled:cursor-not-allowed disabled:bg-muted/40 disabled:text-muted-foreground md:text-sm';
</script>

<!-- Автоправки выключены: сюда вставляют конфиги и списки доменов, где заглавная буква от
     экранной клавиатуры или «исправленное» слово ломают значение (подробнее — input.svelte). -->
<textarea
  bind:this={ref}
  data-slot="textarea"
  bind:value
  class={cn(base, className)}
  autocapitalize="off"
  autocorrect="off"
  spellcheck="false"
  {...restProps}
></textarea>
