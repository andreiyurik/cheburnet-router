<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, ...restProps } = $props();
</script>

<div bind:this={ref} data-slot="separator" role="separator" class={cn('h-px w-full shrink-0 bg-border', className)} {...restProps}></div>
