<script>
  import CircleCheck from '@lucide/svelte/icons/circle-check';
  import CircleAlert from '@lucide/svelte/icons/circle-alert';
  import CircleX from '@lucide/svelte/icons/circle-x';
  // Значок состояния для плашек и строк: lucide (набор shadcn), tone красит его из токенов темы.
  let { tone = 'ok', class: className = '' } = $props();
  const TONE = { ok: 'text-success', warn: 'text-warning', bad: 'text-destructive' };
  const ICON = { ok: CircleCheck, warn: CircleAlert, bad: CircleX };
  const Icon = $derived(ICON[tone]);
</script>

<Icon class="{TONE[tone]} {className}" aria-hidden="true" />
