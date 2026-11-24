<script>
  // Заголовок группы над карточкой (как в настройках телефона): мелкий eyebrow, справа — действие.
  let { id = undefined, tone = 'default', action, children } = $props();
</script>

<div class="mt-8 mb-2 flex min-h-8 items-center justify-between gap-3 px-1">
  <h3 {id} class="text-xs font-semibold tracking-wider uppercase {tone === 'danger' ? 'text-destructive' : 'text-muted-foreground'}">
    {@render children?.()}
  </h3>
  {@render action?.()}
</div>
