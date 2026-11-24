<script module>
  // flush — карточка-список (строки Item сами держат отступы и разделители).
  export const CARD_VARIANTS = {
    default: 'gap-4 p-5',
    flush: 'gap-0 overflow-hidden p-0 divide-y divide-border',
  };
</script>

<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, variant = 'default', children, ...restProps } = $props();
</script>

<section
  bind:this={ref}
  data-slot="card"
  class={cn('flex flex-col rounded-xl border border-border bg-card text-card-foreground shadow-card', CARD_VARIANTS[variant], className)}
  {...restProps}
>
  {@render children?.()}
</section>
