<script>
  // Явный выбор темы поверх системной: data-theme на <html> + localStorage['cheburnet-theme'].
  // До первой отрисовки сохранённый выбор применяет инлайн-скрипт в index.html (иначе мигание).
  let theme = $state(document.documentElement.dataset.theme ?? '');
  const dark = $derived(
    theme ? theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches
  );
  function toggle() {
    theme = dark ? 'light' : 'dark';
    document.documentElement.dataset.theme = theme;
    localStorage.setItem('cheburnet-theme', theme);
  }
</script>

<button class="theme-toggle" onclick={toggle}
  aria-label={dark ? 'Включить светлую тему' : 'Включить тёмную тему'}
  title={dark ? 'Светлая тема' : 'Тёмная тема'}>
  {#if dark}
    <!-- солнце -->
    <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
      <circle cx="12" cy="12" r="4.6" fill="currentColor" />
      <g stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
        <line x1="12" y1="2.5" x2="12" y2="5.2" /><line x1="12" y1="18.8" x2="12" y2="21.5" />
        <line x1="2.5" y1="12" x2="5.2" y2="12" /><line x1="18.8" y1="12" x2="21.5" y2="12" />
        <line x1="5.3" y1="5.3" x2="7.2" y2="7.2" /><line x1="16.8" y1="16.8" x2="18.7" y2="18.7" />
        <line x1="5.3" y1="18.7" x2="7.2" y2="16.8" /><line x1="16.8" y1="7.2" x2="18.7" y2="5.3" />
      </g>
    </svg>
  {:else}
    <!-- луна -->
    <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
      <path d="M20.2 14.5A8.6 8.6 0 0 1 9.5 3.8a8.6 8.6 0 1 0 10.7 10.7Z" fill="currentColor" />
    </svg>
  {/if}
</button>

<style>
  .theme-toggle {
    flex: none;
    margin-left: auto; /* прижата к правому краю header'а */
    width: 2.4rem;
    height: 2.4rem;
    display: grid;
    place-items: center;
    background: var(--card);
    color: var(--muted);
    border: 1px solid var(--line);
    border-radius: 50%;
    cursor: pointer;
    padding: 0;
  }
  .theme-toggle:hover { border-color: var(--accent); color: var(--fg); }
  .theme-toggle:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
  .theme-toggle svg { transition: transform 0.35s; }
  .theme-toggle:active svg { transform: rotate(40deg); }
  @media (prefers-reduced-motion: reduce) {
    .theme-toggle svg { transition: none; }
  }
</style>
