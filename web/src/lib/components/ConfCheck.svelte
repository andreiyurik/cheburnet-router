<script>
  // Живой вердикт формата конфига под полем (checkConf): пусто → hint (если задан),
  // ошибка формата → красная подсказка, похоже на правду → зелёная галка с именем протокола.
  import { checkConf, protocolInfo } from '$lib/logic.js';

  let { id, text = '', hint = '' } = $props();
  const trimmed = $derived((text ?? '').trim());
  const err = $derived(trimmed ? checkConf(id, trimmed) : null);
</script>

{#if !trimmed}
  {#if hint}<span class="mt-1.5 block text-sm text-muted-foreground">{hint}</span>{/if}
{:else if err}
  <span class="mt-1.5 block text-sm text-destructive">{err}</span>
{:else}
  <span class="mt-1.5 block text-sm text-success">✓ По формату похоже на конфиг {protocolInfo(id).name}.</span>
{/if}
