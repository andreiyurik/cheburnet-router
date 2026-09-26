<script>
  import { cn } from '$lib/utils.js';
  // el — сам DOM-узел наружу (bind:el): нужен там, где вызывающему надо .focus().
  let { ref = $bindable(null), el = $bindable(null), value = $bindable(), type = 'text', class: className, ...restProps } = $props();
  // Квирк iOS Safari: фокус на контроле со шрифтом < 16px принудительно зумит всю страницу —
  // поэтому text-base на телефоне и только с md: переходим на мелкий.
  // ШРАМ мобильного ввода: экранная клавиатура по умолчанию ставит заглавную первой буквой и
  // правит «опечатки». Для регистрозависимого кода установки это молчаливый отказ на последнем
  // шаге мастера. Поля здесь технические (код, SSID, слово RESET) — автоправки выключаем всем;
  // перебить можно пропом, он идёт ниже в spread.
  const base = 'flex h-10 w-full min-w-0 rounded-md border border-input bg-background px-3 py-2 '
    + 'text-base transition-colors outline-none placeholder:text-muted-foreground '
    + 'hover:border-muted-foreground focus-visible:border-ring '
    + 'aria-invalid:border-destructive disabled:cursor-not-allowed disabled:opacity-50 md:text-sm';
</script>

{#if type === 'file'}
  <input
    bind:this={el}
    data-slot="input"
    type="file"
    class={cn(base, 'h-auto py-2 file:mr-3 file:rounded-sm file:border-0 file:bg-secondary file:px-3 file:py-1.5 file:text-sm file:text-secondary-foreground', className)}
    {...restProps}
  />
{:else}
  <input
    bind:this={el}
    data-slot="input"
    {type}
    bind:value
    class={cn(base, className)}
    autocapitalize="off"
    autocorrect="off"
    spellcheck="false"
    {...restProps}
  />
{/if}
