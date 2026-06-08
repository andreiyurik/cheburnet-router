<script>
  import { cheburnet } from './lib/ubus.js';
  import Preflight from './lib/steps/Preflight.svelte';
  import Setup from './lib/steps/Setup.svelte';
  import Installing from './lib/steps/Installing.svelte';
  import Status from './lib/steps/Status.svelte';

  // Машина состояний мастера. boot — стартовая проверка «уже установлено?».
  let step = $state('boot');
  let bootError = $state('');

  // Конфиг для установки накапливается на экране Setup и читается экраном Installing.
  let installArgs = $state(null);

  // При загрузке спрашиваем статус: установлен → сразу панель; иначе → preflight.
  async function boot() {
    step = 'boot';
    bootError = '';
    try {
      const s = await cheburnet('status');
      step = s.installed ? 'status' : 'preflight';
    } catch (e) {
      // Статус не ответил — не блокируем установку, начинаем с preflight.
      bootError = e.message;
      step = 'preflight';
    }
  }

  boot();

  function startInstall(args) {
    installArgs = args;
    step = 'installing';
  }
</script>

<main>
  <header>
    <h1>cheburnet</h1>
    <p class="sub">мастер настройки роутера</p>
  </header>

  {#if step === 'boot'}
    <p class="muted">Проверяю состояние роутера…</p>
  {:else if step === 'preflight'}
    {#if bootError}<p class="warn">Статус недоступен: {bootError}</p>{/if}
    <Preflight onReady={() => (step = 'setup')} />
  {:else if step === 'setup'}
    <Setup onSubmit={startInstall} onBack={() => (step = 'preflight')} />
  {:else if step === 'installing'}
    <Installing args={installArgs} onDone={() => (step = 'status')} onRetry={() => (step = 'setup')} />
  {:else if step === 'status'}
    <Status onReinstall={() => (step = 'preflight')} />
  {/if}

  <footer>
    <span class="muted">Образовательный split-tunnel роутер на OpenWrt</span>
  </footer>
</main>
