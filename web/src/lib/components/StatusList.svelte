<script>
  // Сводка «параметр — значение». gap обязателен: на узком экране значение упиралось в подпись
  // и читалось как одно слово («РежимДома — выбранные сайты напрямую»).
  let { children } = $props();
</script>

<ul data-slot="status-list" class="my-2 flex flex-col">
  {@render children?.()}
</ul>
