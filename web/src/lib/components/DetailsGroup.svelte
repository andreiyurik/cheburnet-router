<script>
  import * as Item from '$lib/components/ui/item/index.js';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  // Сворачиваемый раздел: заголовок — строка shadcn Item (иконка, название, текущее значение),
  // тело — нативный <details>: раскрывается по якорю из hero-блока и работает без скриптов.
  let { id = undefined, open = $bindable(false), tone = 'default', summary, description = '', icon: Icon = null, children } = $props();
</script>

<details {id} bind:open class="group/details">
  <summary class="block cursor-pointer before:hidden">
    <Item.Root class="rounded-none hover:bg-accent/50">
      {#if Icon}
        <Item.Media variant="icon" class={tone === 'danger' ? 'text-destructive' : 'text-primary'}><Icon /></Item.Media>
      {/if}
      <Item.Content>
        <Item.Title class="text-base font-semibold {tone === 'danger' ? 'text-destructive' : ''}">{summary}</Item.Title>
        {#if description}<Item.Description>{description}</Item.Description>{/if}
      </Item.Content>
      <Item.Actions>
        <ChevronRight class="size-4 text-muted-foreground transition-transform group-open/details:rotate-90 motion-reduce:transition-none" aria-hidden="true" />
      </Item.Actions>
    </Item.Root>
  </summary>
  <div class="flex flex-col gap-4 px-4 pt-1 pb-5">
    {@render children?.()}
  </div>
</details>
