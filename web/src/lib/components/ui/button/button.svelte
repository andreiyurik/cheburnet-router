<script module>
  // Варианты — обычный объект вместо tv(): читается без знания DSL и не тянет 21 КБ обвязки.
  export const BUTTON_VARIANTS = {
    default: 'bg-primary text-primary-foreground font-semibold hover:bg-primary/90',
    outline: 'border border-border bg-card text-foreground hover:border-primary hover:bg-accent',
    secondary: 'bg-secondary text-secondary-foreground hover:bg-accent',
    ghost: 'text-foreground hover:bg-accent',
    destructive: 'bg-destructive text-destructive-foreground font-semibold hover:bg-destructive/90',
    'destructive-outline': 'border border-destructive text-destructive hover:bg-destructive hover:text-destructive-foreground',
    link: 'text-primary underline underline-offset-3 hover:no-underline disabled:bg-transparent',
  };
  export const BUTTON_SIZES = {
    default: 'h-10 px-4 text-sm',
    sm: 'h-8 px-3 text-xs',
    // lg — для главного действия экрана: на телефоне палец попадает без прицеливания.
    lg: 'h-12 px-6 text-base',
    icon: 'size-10',
    // link-вариант живёт внутри абзаца: своей высоты и отступов у него быть не должно.
    inline: 'h-auto p-0 text-[inherit]',
  };
</script>

<script>
  import { cn } from '$lib/utils.js';

  let {
    class: className,
    variant = 'default',
    size = variant === 'link' ? 'inline' : 'default',
    ref = $bindable(null),
    href = undefined,
    type = 'button',
    disabled,
    children,
    ...restProps
  } = $props();

  // Неактивная кнопка красится в muted, а не гасится прозрачностью: залитая primary с opacity-50
  // на светлой теме читалась как обычная кнопка, и человек жал по ней впустую.
  // Утилиты с псевдоклассом (`disabled:`) специфичнее простых — заливка варианта перебивается
  // надёжно, без tailwind-merge.
  const base = 'inline-flex shrink-0 items-center justify-center gap-2 whitespace-nowrap rounded-md '
    + 'transition-colors outline-none select-none '
    + 'disabled:pointer-events-none disabled:border-border disabled:bg-muted '
    + 'disabled:font-normal disabled:text-muted-foreground '
    + '[&_svg]:pointer-events-none [&_svg:not([class*=size-])]:size-4';
</script>

{#if href}
  <a
    bind:this={ref}
    data-slot="button"
    class={cn(base, BUTTON_VARIANTS[variant], BUTTON_SIZES[size], className)}
    href={disabled ? undefined : href}
    aria-disabled={disabled}
    {...restProps}
  >
    {@render children?.()}
  </a>
{:else}
  <button
    bind:this={ref}
    data-slot="button"
    class={cn(base, BUTTON_VARIANTS[variant], BUTTON_SIZES[size], className)}
    {type}
    {disabled}
    {...restProps}
  >
    {@render children?.()}
  </button>
{/if}
