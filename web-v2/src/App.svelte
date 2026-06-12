<script>
  import { cheburnet } from './lib/ubus.js';
  import Preflight from './lib/steps/Preflight.svelte';
  import LanConflict from './lib/steps/LanConflict.svelte';
  import Setup from './lib/steps/Setup.svelte';
  import Confirm from './lib/steps/Confirm.svelte';
  import Installing from './lib/steps/Installing.svelte';
  import Status from './lib/steps/Status.svelte';

  // Машина состояний мастера. boot — стартовая проверка «уже установлено?».
  let step = $state('boot');
  let bootError = $state('');

  // Есть ли у роутера Wi-Fi-радио (из status). null = статус не ответил, точно не знаем →
  // Setup покажет поля Wi-Fi как необязательные (не блокируем wired-only роутер).
  let wirelessPresent = $state(null);

  // Каталог DNS-провайдеров (из status) + дефолт — для селектора фильтрации на Setup.
  let dnsProviders = $state([]);
  let dnsProviderDefault = $state('');

  // Конфиг для установки накапливается на экране Setup, подтверждается на Confirm и
  // читается экраном Installing.
  let installArgs = $state(null);
  let lanConflict = $state(null); // ответ check_lan_conflict при конфликте

  // При загрузке спрашиваем статус: установлен → сразу панель; иначе — проверяем пересечение
  // LAN/WAN-подсетей (его надо чинить ДО мастера, preflight такое не пропустит) → preflight.
  async function boot() {
    step = 'boot';
    bootError = '';
    try {
      const s = await cheburnet('status');
      wirelessPresent = s.wireless_present ?? null;
      dnsProviders = s.dns_providers ?? [];
      dnsProviderDefault = s.dns_provider ?? '';
      if (s.installed) {
        step = 'status';
        return;
      }
      try {
        const c = await cheburnet('check_lan_conflict');
        if (c.conflict && c.suggest_ip) {
          lanConflict = c;
          step = 'lanconflict';
          return;
        }
      } catch {
        // детект не ответил — не блокируем установку
      }
      step = 'preflight';
    } catch (e) {
      // Статус не ответил — не блокируем установку, начинаем с preflight.
      bootError = e.message;
      step = 'preflight';
    }
  }

  boot();

  function toConfirm(args) {
    installArgs = args;
    step = 'confirm';
  }
</script>

<main>
  <header>
    <h1>cheburnet</h1>
    <p class="sub">мастер настройки роутера</p>
  </header>

  {#if step === 'boot'}
    <p class="muted">Проверяю состояние роутера…</p>
  {:else if step === 'lanconflict'}
    <LanConflict info={lanConflict} onSkip={() => (step = 'preflight')} />
  {:else if step === 'preflight'}
    {#if bootError}<p class="warn">Статус недоступен: {bootError}</p>{/if}
    <Preflight onReady={() => (step = 'setup')} />
  {:else if step === 'setup'}
    <Setup onSubmit={toConfirm} onBack={() => (step = 'preflight')} {wirelessPresent} {dnsProviders} {dnsProviderDefault} initial={installArgs} />
  {:else if step === 'confirm'}
    <Confirm args={installArgs} {dnsProviders} onBack={() => (step = 'setup')} onConfirm={() => (step = 'installing')} />
  {:else if step === 'installing'}
    <Installing args={installArgs} onDone={() => (step = 'status')} onRetry={() => (step = 'setup')} />
  {:else if step === 'status'}
    <Status onReinstall={() => (step = 'preflight')} />
  {/if}

  <footer>
    <span class="muted">Образовательный split-tunnel роутер на OpenWrt</span>
  </footer>
</main>
