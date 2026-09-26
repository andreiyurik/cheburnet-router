<script>
  import { cn } from '$lib/utils.js';
  // Нативный <dialog>: ловушка фокуса, Esc и затемнение — от браузера, без единой строки JS
  // сверх showModal/close. Библиотека диалогов стоила бы 20 КБ gzip ради того же поведения.
  let { open = $bindable(false), class: className, children, ...restProps } = $props();
  let el = $state(null);

  $effect(() => {
    if (!el) return;
    if (open && !el.open) el.showModal();
    if (!open && el.open) el.close();
  });
</script>

<dialog
  bind:this={el}
  data-slot="dialog"
  onclose={() => (open = false)}
  onclick={(e) => { if (e.target === el) open = false; }}
  class={cn(
    'm-auto w-[min(92vw,26rem)] rounded-xl border border-border bg-card p-6 text-card-foreground shadow-card',
    'backdrop:bg-[rgb(28_20_12/0.55)]',
    className
  )}
  {...restProps}
>
  <!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
  <div class="flex flex-col gap-4" onclick={(e) => e.stopPropagation()}>
    {@render children?.()}
  </div>
</dialog>
