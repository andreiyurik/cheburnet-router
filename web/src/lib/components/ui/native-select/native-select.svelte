<script>
  import { cn } from '$lib/utils.js';
  // Нативный <select>, а не выпадающий список на JS: на телефоне система показывает
  // привычное колесо выбора, и работает это без единого килобайта скриптов.
  let { ref = $bindable(null), value = $bindable(), class: className, children, ...restProps } = $props();
</script>

<div data-slot="native-select-wrapper" class={cn('relative w-full has-[select:disabled]:opacity-50', className)}>
  <select
    bind:this={ref}
    bind:value
    data-slot="native-select"
    class="h-10 w-full appearance-none rounded-md border border-input bg-background py-2 pr-10 pl-3 text-base transition-colors outline-none hover:border-muted-foreground focus-visible:border-ring disabled:cursor-not-allowed md:text-sm"
    {...restProps}
  >
    {@render children?.()}
  </select>
  <!-- Стрелка — инлайновый SVG: иконочная библиотека ради одной галочки не нужна. -->
  <svg class="pointer-events-none absolute top-1/2 right-3 size-4 -translate-y-1/2 text-muted-foreground"
       viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
       stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="m6 9 6 6 6-6" />
  </svg>
</div>
