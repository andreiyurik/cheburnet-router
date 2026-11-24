<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, level = 2, size = 'default', children, ...restProps } = $props();
  const SIZES = { default: 'text-2xl', sm: 'text-lg' };
</script>

<svelte:element
  this={`h${level}`}
  bind:this={ref}
  data-slot="card-title"
  class={cn('font-display leading-snug', SIZES[size], className)}
  {...restProps}
>
  {@render children?.()}
</svelte:element>
