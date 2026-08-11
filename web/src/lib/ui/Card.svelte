<script>
  let { title, children } = $props();
</script>

<section class="ui-card">
  {#if title}<h2>{title}</h2>{/if}
  {@render children?.()}
</section>

<style>
  .ui-card {
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: var(--radius-lg);
    padding: 1.25rem;
    /* Едва заметный подъём над фоном страницы — без него карточка держится только на границе
       (--line), которая на тёмной теме почти не видна и поверхность выглядит плоской. */
    box-shadow: 0 1px 2px rgb(46 30 12 / 0.05), 0 10px 28px -16px rgb(46 30 12 / 0.22);
  }
  .ui-card h2 { margin: 0 0 0.75rem; font-family: var(--font-display); font-size: 1.25rem; }
</style>
