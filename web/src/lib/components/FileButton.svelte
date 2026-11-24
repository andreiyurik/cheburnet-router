<script>
  import Button from '$lib/components/ui/button/button.svelte';
  import FileUp from '@lucide/svelte/icons/file-up';
  // Выбор файла кнопкой: нативный input скрыт — его «Choose File / No file chosen» не
  // переводится и выбивается из темы. Имя выбранного файла показываем сами.
  let { accept, onchange, disabled = false, children } = $props();
  let input = $state(null);
  let name = $state('');
</script>

<div class="flex min-w-0 items-center gap-3">
  <input bind:this={input} type="file" class="sr-only" tabindex="-1" {accept} {disabled}
         onchange={(e) => { name = e.currentTarget.files?.[0]?.name ?? ''; onchange?.(e); }} />
  <Button variant="outline" {disabled} onclick={() => input?.click()}><FileUp />{@render children?.()}</Button>
  {#if name}<span class="truncate text-sm text-muted-foreground">{name}</span>{/if}
</div>
