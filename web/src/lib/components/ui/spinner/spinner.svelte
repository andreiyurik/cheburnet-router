<script>
  import { cn } from '$lib/utils.js';
  let { class: className, 'aria-label': ariaLabel = 'Идёт работа', ...restProps } = $props();
</script>

<svg
  data-slot="spinner"
  role="status"
  aria-label={ariaLabel}
  class={cn('size-4 shrink-0 animate-spin text-primary motion-reduce:animate-none', className)}
  viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"
  {...restProps}
>
  <circle cx="12" cy="12" r="9" class="opacity-25" />
  <path d="M21 12a9 9 0 0 0-9-9" />
</svg>
