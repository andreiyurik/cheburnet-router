<script>
  import { cn } from '$lib/utils.js';
  let { ref = $bindable(null), class: className, children, ...restProps } = $props();
</script>

<!-- Сетка из shadcn-svelte card-header (под CardAction); px-6 снят — отступ у нашего Root. -->
<header
  bind:this={ref}
  data-slot="card-header"
  class={cn('@container/card-header grid auto-rows-min grid-rows-[auto_auto] items-start gap-1 has-data-[slot=card-action]:grid-cols-[1fr_auto] [.border-b]:pb-5', className)}
  {...restProps}
>
  {@render children?.()}
</header>
