<script>
  import * as Item from '$lib/components/ui/item/index.js';
  import Spinner from '$lib/components/ui/spinner/spinner.svelte';
  import Circle from '@lucide/svelte/icons/circle';
  import StatusIcon from './StatusIcon.svelte';
  // Список проверок (preflight) и чеклист установки — строки shadcn Item.
  // items: [{ mark: 'ok'|'soft'|'bad'|'pending'|'running', text, fix? }]
  let { items } = $props();
  const TONE = { ok: 'ok', soft: 'warn', bad: 'bad' };
</script>

<Item.Group class="rounded-lg border border-border">
  {#each items as it, i}
    {#if i > 0}<Item.Separator />{/if}
    <Item.Root size="sm" data-mark={it.mark}>
      <Item.Media>
        {#if it.mark === 'running'}<Spinner class="size-4" />
        {:else if it.mark === 'pending'}<Circle class="size-4 text-muted-foreground/50" aria-hidden="true" />
        {:else}<StatusIcon tone={TONE[it.mark]} class="size-4" />{/if}
      </Item.Media>
      <Item.Content>
        <Item.Title class={it.mark === 'pending' ? 'text-muted-foreground' : ''}>{it.text}</Item.Title>
        {#if it.fix}<Item.Description>{it.fix}</Item.Description>{/if}
      </Item.Content>
    </Item.Root>
  {/each}
</Item.Group>
