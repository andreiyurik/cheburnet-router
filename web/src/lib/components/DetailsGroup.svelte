<script>
  // Свёрнутая группа панели: выглядит как раздел, а не как спрятанный журнал — иначе человек
  // не догадается, что внутри есть действия. Нативный <details>, а не JS-аккордеон: он
  // раскрывается по якорю из hero-баннера и работает без скриптов.
  let { id = undefined, open = $bindable(false), tone = 'default', summary, children } = $props();
</script>

<details {id} bind:open class="border-t border-border">
  <summary class="cursor-pointer py-4 font-semibold marker:text-muted-foreground {tone === 'danger' ? 'text-destructive' : 'text-foreground'}">
    {summary}
  </summary>
  <div class="pb-6">
    {@render children?.()}
  </div>
</details>
