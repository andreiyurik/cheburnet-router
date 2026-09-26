<script>
  // Индикатор шагов мастера: точки + подпись «Шаг N из M».
  let { steps, index } = $props();
</script>

<nav class="mb-3 flex items-center gap-1.5 pl-1" aria-label="Шаги мастера">
  {#each steps as _, i}
    <span class="size-2 rounded-full {i === index ? 'bg-primary' : i < index ? 'bg-muted-foreground' : 'bg-border'}"></span>
  {/each}
  <span class="ml-2 text-sm text-muted-foreground">Шаг {index + 1} из {steps.length} — {steps[index].label}</span>
</nav>
