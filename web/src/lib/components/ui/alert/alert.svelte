<script module>
  // Тон = смысл: info — нейтральная подсказка, warning — «впритык», destructive — тревога.
  // Тонируем фон через color-mix (Tailwind /NN), поэтому цвет один на рамку, текст и заливку.
  export const ALERT_VARIANTS = {
    info: 'border-primary/40 bg-primary/10 text-foreground',
    success: 'border-success/40 bg-success/10 text-foreground',
    warning: 'border-warning/45 bg-warning/10 text-foreground',
    destructive: 'border-destructive/50 bg-destructive/10 text-foreground',
  };
</script>

<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, variant = 'info', children, ...restProps } = $props();
</script>

<div
  bind:this={ref}
  data-slot="alert"
  data-variant={variant}
  role="alert"
  class={cn('flex gap-3 rounded-md border px-4 py-3 text-sm [&>svg]:mt-0.5 [&>svg]:size-5 [&>svg]:shrink-0 [&_a]:font-semibold [&_a]:text-inherit [&_a]:underline-offset-2', ALERT_VARIANTS[variant], className)}
  {...restProps}
>
  {@render children?.()}
</div>
