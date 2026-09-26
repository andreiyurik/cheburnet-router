<script>
  import { cn } from '$lib/utils.js';
  // Радио-карточка: рамка подсвечивается при выборе — вместо голого кружка с текстом рядом.
  // group — тот же bindable, что у нативного bind:group (Svelte форвардит его сквозь компонент).
  // ИНВАРИАНТ: прозрачный input покрывает всю карточку (см. checkbox.svelte — тот же приём).
  let { group = $bindable(), value, disabled = false, class: className, children, ...restProps } = $props();
  const selected = $derived(group === value);
</script>

<label
  class={cn(
    'relative my-2 flex cursor-pointer items-start gap-3 rounded-md border-2 p-4 transition-colors',
    selected ? 'border-primary bg-primary/8' : 'border-border hover:border-primary/50 hover:bg-accent/60',
    disabled && 'cursor-not-allowed opacity-60 hover:border-border hover:bg-transparent',
    className
  )}
>
  <input
    type="radio"
    bind:group
    {value}
    {disabled}
    class="absolute inset-0 m-0 size-full cursor-pointer opacity-0 disabled:cursor-not-allowed"
    {...restProps}
  />
  <span
    aria-hidden="true"
    class={cn('mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border-2', selected ? 'border-primary' : 'border-input')}
  >
    {#if selected}<span class="size-2.5 rounded-full bg-primary"></span>{/if}
  </span>
  <span class="text-sm">{@render children?.()}</span>
</label>
