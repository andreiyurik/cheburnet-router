<script>
  import * as Item from '$lib/components/ui/item/index.js';
  // Строка сводки: подпись (может нести ссылку) над значением — на узком экране длинное значение
  // не прыгает по ширине. tone красит значение.
  let { tone = 'default', value = '', label, children } = $props();
  const TONE = { ok: 'text-success', bad: 'text-destructive', default: '' };
</script>

<Item.Root size="sm">
  <Item.Content>
    <Item.Description>{#if label}{label}{/if}{@render children?.()}</Item.Description>
    <Item.Title class="text-base font-semibold {TONE[tone]}">{value}</Item.Title>
  </Item.Content>
</Item.Root>
