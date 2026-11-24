<script>
  import { setContext } from 'svelte';
  import * as F from '$lib/components/ui/field/index.js';
  import Badge from '$lib/components/ui/badge/badge.svelte';
  // Обёртка над shadcn Field: подпись связана с контролом через id из контекста (Input/Textarea/
  // NativeSelect берут его сами) — поэтому getByLabel и скринридер находят поле без ручных id.
  let { label, hint = '', error = '', required = false, optional = false, class: className, el = $bindable(), children } = $props();
  const id = $props.id();
  // ref у F.Field со значением по умолчанию, а bind:el снаружи приходит undefined — прямой проброс запрещён.
  let node = $state(null);
  $effect(() => { el = node; });
  setContext('field-id', id);
</script>

<F.Field bind:ref={node} class={className} data-invalid={error ? true : undefined}>
  <F.Label for={id}>
    {label}
    {#if required}<Badge variant="outline">обязательно</Badge>{/if}
    {#if optional}<span class="font-normal text-muted-foreground">необязательно</span>{/if}
  </F.Label>
  {@render children?.()}
  {#if error}
    <F.Error>{error}</F.Error>
  {:else if hint}
    <F.Description>{hint}</F.Description>
  {/if}
</F.Field>
