<script>
  // Радио-карточка: рамка подсвечивается акцентом при выборе — вместо голого кружка с текстом
  // рядом. group — тот же bindable, что у нативного bind:group (Svelte форвардит его сквозь
  // компонент как обычную реактивную привязку).
  let { group = $bindable(), value, disabled = false, children } = $props();
</script>

<label class="ui-radio" class:disabled class:checked={group === value}>
  <input type="radio" bind:group value={value} {disabled} />
  <span class="ui-radio-dot" aria-hidden="true"></span>
  <span class="ui-radio-content">{@render children?.()}</span>
</label>

<style>
  .ui-radio {
    position: relative;
    display: flex;
    align-items: flex-start;
    gap: 0.65rem;
    border: 1px solid var(--line);
    border-radius: var(--radius-md);
    padding: 0.7rem 0.85rem;
    margin: 0.5rem 0;
    cursor: pointer;
    transition: border-color 0.15s, background-color 0.15s;
  }
  .ui-radio:hover:not(.disabled) { border-color: var(--accent); }
  .ui-radio.checked { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 8%, transparent); }
  .ui-radio.disabled { cursor: not-allowed; opacity: 0.6; }

  /* Настоящий input остаётся кликабельным на всю карточку (не только на кружок) — просто
     прозрачный. ИНВАРИАНТ: размер должен покрывать весь label, а не схлопываться в 0×0 —
     иначе элемент считается невидимым для Playwright/скринридеров и клик по нему не проходит. */
  .ui-radio input {
    position: absolute;
    inset: 0;
    /* input — replaced-элемент: одного inset:0 недостаточно, без явных width/height он
       остаётся родного размера (~13px) и Playwright/скринридеры считают его точечным. */
    width: 100%;
    height: 100%;
    margin: 0;
    opacity: 0;
    cursor: pointer;
  }

  .ui-radio-dot {
    flex: none;
    width: 1.1rem;
    height: 1.1rem;
    margin-top: 0.15rem;
    border-radius: 50%;
    border: 1.5px solid var(--line);
    position: relative;
  }
  .ui-radio.checked .ui-radio-dot { border-color: var(--accent); }
  .ui-radio.checked .ui-radio-dot::after {
    content: '';
    position: absolute;
    inset: 3px;
    border-radius: 50%;
    background: var(--accent);
  }
  .ui-radio input:focus-visible + .ui-radio-dot {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }

  .ui-radio-content { font-size: 0.95rem; }
</style>
