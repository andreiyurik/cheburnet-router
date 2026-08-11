<script>
  // variant: 'default' | 'primary' | 'danger' | 'link'. wide — на всю ширину (см. button.danger.wide в app.css).
  let { variant = 'default', wide = false, children, ...rest } = $props();
</script>

<button class="ui-btn {variant}" class:wide {...rest}>
  {@render children?.()}
</button>

<style>
  .ui-btn {
    background: var(--card);
    color: var(--fg);
    border: 1px solid var(--line);
    border-radius: var(--radius-md);
    padding: 0.6rem 1.1rem;
    font-size: 0.95rem;
    cursor: pointer;
  }
  .ui-btn:hover:not(:disabled) { border-color: var(--accent); }
  .ui-btn:disabled { opacity: 0.5; cursor: default; }

  .ui-btn.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-fg); font-weight: 600; }

  .ui-btn.danger { border-color: var(--bad); color: var(--bad); }
  .ui-btn.danger:hover:not(:disabled) { background: var(--bad); color: var(--bad-fg); }

  .ui-btn.link { background: none; border: none; padding: 0; color: var(--accent); text-decoration: underline; font-size: inherit; }

  .ui-btn.wide { display: block; width: 100%; padding: 0.8rem; font-weight: 600; }
</style>
