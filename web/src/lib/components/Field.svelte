<script>
  import { cn } from '$lib/utils.js';
  // Поле формы: подпись + контрол + подсказка/ошибка. <label> обёрнут вокруг контрола —
  // поэтому getByLabel находит поле без ручной расстановки id (и скринридер тоже).
  // invalid подсвечивает рамку через aria-invalid самого контрола (см. input.svelte).
  let { label, hint = '', error = '', required = false, optional = false, class: className, el = $bindable(), children } = $props();
</script>

<label bind:this={el} class={cn('block', className)}>
  <span class="mb-1.5 flex flex-wrap items-baseline gap-1.5 text-sm font-semibold">
    {label}
    {#if required}<span class="font-semibold text-primary">(обязательно)</span>{/if}
    {#if optional}<span class="font-normal text-muted-foreground">(необязательно)</span>{/if}
  </span>
  {@render children?.()}
  {#if error}
    <span class="mt-1.5 block text-sm text-destructive">{error}</span>
  {:else if hint}
    <span class="mt-1.5 block text-sm text-muted-foreground">{hint}</span>
  {/if}
</label>
