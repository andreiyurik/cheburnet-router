<script>
  // Живой вердикт формата конфига под полем (checkConf): пусто → hint (если задан),
  // ошибка формата → warn с подсказкой, похоже на правду → зелёная галка с именем протокола.
  import { checkConf, protocolInfo } from '../logic.js';
  let { id, text = '', hint = '' } = $props();
  const trimmed = $derived((text ?? '').trim());
  const err = $derived(trimmed ? checkConf(id, trimmed) : null);
</script>

{#if !trimmed}
  {#if hint}<small class="muted">{hint}</small>{/if}
{:else if err}
  <small class="warn">{err}</small>
{:else}
  <small class="ok-hint">✓ По формату похоже на конфиг {protocolInfo(id).name}.</small>
{/if}
