<script>
  let { value = $bindable(), children, ...rest } = $props();
</script>

<div class="ui-select">
  <select bind:value {...rest}>
    {@render children?.()}
  </select>
</div>

<style>
  .ui-select {
    position: relative;
  }
  /* Стрелка нарисована CSS вместо картинки/иконочного шрифта — нулевой лишний ассет. */
  .ui-select::after {
    content: '';
    position: absolute;
    right: 0.9rem;
    top: 50%;
    width: 0.5rem;
    height: 0.5rem;
    border-right: 1.5px solid var(--muted);
    border-bottom: 1.5px solid var(--muted);
    transform: translateY(-70%) rotate(45deg);
    pointer-events: none;
  }
  select {
    width: 100%;
    appearance: none;
    background: var(--bg);
    color: var(--fg);
    border: 1px solid var(--line);
    border-radius: var(--radius-md);
    padding: 0.6rem 2.1rem 0.6rem 0.6rem;
    font-family: inherit;
    font-size: 0.9rem;
    cursor: pointer;
    transition: border-color 0.15s;
  }
  select:hover:not(:disabled) { border-color: var(--muted); }
  select:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; border-color: var(--accent); }
  select:disabled { opacity: 0.5; cursor: default; }
  /* Квирк iOS: шрифт < 16px на фокусе зумит страницу — подробнее в app.css. */
  @media (max-width: 640px) { select { font-size: 1rem; } }
</style>
