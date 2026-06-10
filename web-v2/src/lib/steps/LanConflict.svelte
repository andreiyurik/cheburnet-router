<script>
  import { cheburnet } from '../ubus.js';

  // info — ответ check_lan_conflict: { lan_cidr, wan_cidr, suggest_ip }.
  // onSkip — продолжить без смены (preflight всё равно отметит конфликт).
  let { info, onSkip } = $props();

  let token = $state('');
  let error = $state('');
  let busy = $state(false);
  let applied = $state(null); // new_ip после успешного применения

  async function apply() {
    error = '';
    if (token.trim().length === 0) {
      error = 'Введите install-токен (его напечатал bootstrap по SSH).';
      return;
    }
    busy = true;
    try {
      const r = await cheburnet('apply_lan_ip', { ip: info.suggest_ip, token: token.trim() });
      applied = r.new_ip;
    } catch (e) {
      error = e.message;
    } finally {
      busy = false;
    }
  }
</script>

<section>
  <h2>Конфликт подсетей</h2>

  {#if applied}
    <p class="ok-msg">✓ Новый адрес применён. Сеть роутера перезапускается…</p>
    <ol>
      <li>Подождите ~15 секунд, пока роутер перезапустит сеть.</li>
      <li>Переподключитесь к роутеру (Wi-Fi/кабель): устройство получит адрес из новой подсети.
        Если не получило — выключите и включите Wi-Fi (или переткните кабель).</li>
      <li>Откройте мастер по новому адресу:
        <strong><a href={`http://${applied}/cheburnet/`}>http://{applied}/cheburnet/</a></strong></li>
    </ol>
  {:else}
    <p>
      Подсеть LAN роутера (<code>{info.lan_cidr}</code>) пересекается с подсетью провайдера
      (<code>{info.wan_cidr}</code>). Так бывает, когда роутер подключён за другим роутером с
      той же подсетью. Маршрутизация в таком виде работать не будет — preflight установку не
      пропустит.
    </p>
    <p>
      Решение: сменить адрес LAN на свободный — предлагаем
      <strong>{info.suggest_ip}</strong>. После смены нужно переподключиться к роутеру по
      новому адресу (гайд покажем).
    </p>

    <label>
      <span>Install-токен</span>
      <input type="text" bind:value={token} placeholder="из вывода bootstrap по SSH" />
      <small class="muted">Смена адреса рвёт соединения — поэтому требует токен владельца.</small>
    </label>

    {#if error}<p class="warn">{error}</p>{/if}

    <div class="row">
      <button disabled={busy} onclick={onSkip}>Продолжить без смены</button>
      <button class="primary" disabled={busy} onclick={apply}>
        {busy ? 'Применяю…' : `Сменить LAN-адрес на ${info.suggest_ip}`}
      </button>
    </div>
  {/if}
</section>
