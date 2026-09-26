<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, children, ...restProps } = $props();
</script>

<div bind:this={ref} data-slot="card-content" class={cn('flex flex-col gap-4', className)} {...restProps}>
  {@render children?.()}
</div>
