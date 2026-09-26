<script>
  // Журнал: моноширинный блок с прокруткой. live — живая консоль установки: полоска, всегда
  // прокрученная к свежим строкам (ниже по коду — bind:el у вызывающего).
  let { text, live = false, expanded = false, el = $bindable(null), class: className = '' } = $props();
</script>

<pre
  bind:this={el}
  data-slot="log"
  class="overflow-auto rounded-md border border-border bg-background p-3 text-xs break-words whitespace-pre-wrap
         {live ? (expanded ? 'my-3 max-h-none' : 'my-3 max-h-45') : 'max-h-65'} {className}">{text}</pre>
