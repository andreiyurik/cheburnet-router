<script>
  import { cn } from '$lib/utils.js';
  // Текстовая колонка плашки: заголовок и описание друг под другом, рядом со значком.
  let { class: className, children } = $props();
</script>

<div class={cn('flex min-w-0 flex-col gap-1', className)}>
  {@render children?.()}
</div>
