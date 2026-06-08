<script>
  import { onDestroy } from 'svelte';
  import { cheburnet } from '../ubus.js';

  // onReinstall — запустить мастер заново (с preflight).
  let { onReinstall } = $props();

  let s = $state(null);
  let error = $state('');
  let action = $state(''); // текст результата/ошибки управляющего действия
  let busy = $state(false);
  let timer = null;

  async function refresh() {
    try {
      s = await cheburnet('status');
      error = '';
    } catch (e) {
      error = e.message;
    }
  }

  // Управление (set_mode/update_list) — admin-методы: с анонимной сессией придёт
  // PERMISSION_DENIED. Показываем честно: эти действия требуют входа (следующая итерация).
  async function setMode(mode) {
    busy = true;
    action = '';
    try {
      await cheburnet('set_mode', { mode });
      action = `Режим переключён на ${mode}.`;
      await refresh();
    } catch (e) {
      action = `Не удалось сменить режим: ${e.message} (управление требует входа).`;
    } finally {
      busy = false;
    }
  }

  async function updateList() {
    busy = true;
    action = '';
    try {
      const r = await cheburnet('update_list');
      action = `Список обновлён: ${r.direct_domains} доменов.`;
      await refresh();
    } catch (e) {
      action = `Не удалось обновить список: ${e.message} (управление требует входа).`;
    } finally {
      busy = false;
    }
  }

  function hs(age) {
    if (age == null) return 'нет рукопожатия';
    if (age < 0) return '—';
    if (age < 120) return `${age} с назад`;
    return `${Math.floor(age / 60)} мин назад`;
  }

  refresh();
  timer = setInterval(refresh, 5000);
  onDestroy(() => timer && clearInterval(timer));
</script>

<section>
  <h2>Состояние</h2>

  {#if error}<p class="warn">{error}</p>{/if}

  {#if s}
    <ul class="status">
      <li><span>Режим</span><strong>{s.mode === 'travel' ? 'TRAVEL (всё в туннель)' : 'HOME (split)'}</strong></li>
      <li><span>Домены прямого доступа</span><strong>{s.direct_domains}</strong></li>
      <li><span>Туннель (handshake)</span><strong>{hs(s.awg_handshake_age)}</strong></li>
      <li class:ok={s.dns_up} class:bad={!s.dns_up}><span>DNS</span><strong>{s.dns_up ? 'работает' : 'нет'}</strong></li>
      <li class:ok={s.doh_up} class:bad={!s.doh_up}><span>Шифрованный DNS</span><strong>{s.doh_up ? 'работает' : 'нет'}</strong></li>
    </ul>

    <h3>Управление</h3>
    <div class="row">
      <button disabled={busy} onclick={() => setMode(s.mode === 'travel' ? 'home' : 'travel')}>
        {s.mode === 'travel' ? 'Включить HOME' : 'Включить TRAVEL'}
      </button>
      <button disabled={busy} onclick={updateList}>Обновить список доменов</button>
    </div>
    {#if action}<p class="muted">{action}</p>{/if}

    <p class="muted small">Управляющие действия требуют входа (root) — вход добавим в следующей итерации.</p>
  {:else}
    <p class="muted">Загрузка…</p>
  {/if}

  <hr />
  <button onclick={onReinstall}>Настроить заново</button>
</section>
