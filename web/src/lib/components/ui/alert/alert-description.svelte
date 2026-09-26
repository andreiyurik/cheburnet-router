<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, children, ...restProps } = $props();
</script>

<div bind:this={ref} data-slot="alert-description" class={cn('[&_p]:mt-2 [&_p:first-child]:mt-0', className)} {...restProps}>
  {@render children?.()}
</div>
