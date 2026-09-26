<script module>
  export const BADGE_VARIANTS = {
    default: 'border-transparent bg-primary text-primary-foreground',
    outline: 'border-border text-foreground',
    success: 'border-success/40 bg-success/10 text-success',
    warning: 'border-warning/40 bg-warning/10 text-warning',
    destructive: 'border-destructive/40 bg-destructive/10 text-destructive',
  };
</script>

<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, variant = 'default', children, ...restProps } = $props();
</script>

<span
  bind:this={ref}
  data-slot="badge"
  class={cn('inline-flex w-fit shrink-0 items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-semibold whitespace-nowrap', BADGE_VARIANTS[variant], className)}
  {...restProps}
>
  {@render children?.()}
</span>
