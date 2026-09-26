<script>
  // Eyebrow-лейбл раздела, а не подзаголовок: маленький размер + линия дают чёткую границу
  // между смысловыми блоками формы. Крупные ЗАГЛАВНЫЕ спорили по весу с обычным текстом.
  let { id = undefined, tone = 'default', children } = $props();
</script>

<h3 {id} class="mt-6 border-b border-border pb-1.5 text-xs font-semibold tracking-wider uppercase {tone === 'danger' ? 'text-destructive' : 'text-muted-foreground'}">
  {@render children?.()}
</h3>
