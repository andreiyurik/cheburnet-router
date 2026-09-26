<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, children, ...restProps } = $props();
</script>

<label
  bind:this={ref}
  data-slot="label"
  class={cn('flex items-center gap-2 text-sm font-semibold select-none', className)}
  {...restProps}
>
  {@render children?.()}
</label>
