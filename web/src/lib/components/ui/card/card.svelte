<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, children, ...restProps } = $props();
</script>

<section
  bind:this={ref}
  data-slot="card"
  class={cn('flex flex-col gap-4 rounded-xl border border-border bg-card p-5 text-card-foreground shadow-card', className)}
  {...restProps}
>
  {@render children?.()}
</section>
