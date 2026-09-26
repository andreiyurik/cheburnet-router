<script>
  import { cn } from '$lib/utils.js';
  // Нативный input под прозрачным слоем: клавиатура, скринридеры и Playwright видят настоящий
  // чекбокс, а галочку рисуем сами. ИНВАРИАНТ: input обязан покрывать весь квадрат (inset-0 +
  // size-full) — схлопнувшись в 0×0, он считается невидимым и клик по нему не проходит.
  let { checked = $bindable(false), class: className, ...restProps } = $props();
</script>

<span class={cn('relative inline-flex size-5 shrink-0', className)}>
  <input
    type="checkbox"
    bind:checked
    data-slot="checkbox"
    class="peer absolute inset-0 m-0 size-full cursor-pointer opacity-0 disabled:cursor-not-allowed"
    {...restProps}
  />
  <span
    aria-hidden="true"
    class="pointer-events-none flex size-5 items-center justify-center rounded-sm border border-input bg-background text-primary-foreground transition-colors peer-checked:border-primary peer-checked:bg-primary peer-checked:[&>svg]:opacity-100 peer-disabled:opacity-50"
  >
    <svg class="size-3.5 opacity-0 transition-opacity" viewBox="0 0 24 24" fill="none"
         stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
      <path d="M20 6 9 17l-5-5" />
    </svg>
  </span>
</span>
