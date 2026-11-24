<script>
  import * as Item from '$lib/components/ui/item/index.js';
  // Сводка «параметр — значение»: группа строк Item в рамке.
  let { children } = $props();
</script>

<Item.Group data-slot="status-list" class="rounded-lg border border-border divide-y divide-border">
  {@render children?.()}
</Item.Group>
