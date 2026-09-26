<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, children, ...restProps } = $props();
</script>

<p bind:this={ref} data-slot="alert-title" class={cn('font-semibold', className)} {...restProps}>
  {@render children?.()}
</p>
