<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, children, ...restProps } = $props();
</script>

<header bind:this={ref} data-slot="card-header" class={cn('flex flex-col gap-1', className)} {...restProps}>
  {@render children?.()}
</header>
