<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, level = 2, children, ...restProps } = $props();
</script>

<svelte:element
  this={`h${level}`}
  bind:this={ref}
  data-slot="card-title"
  class={cn('font-display text-2xl leading-snug', className)}
  {...restProps}
>
  {@render children?.()}
</svelte:element>
