<script>
  import { cheburnet } from '../ubus.js';
  import * as Card from '$lib/components/ui/card/index.js';
  import Button from '$lib/components/ui/button/button.svelte';
  import Input from '$lib/components/ui/input/input.svelte';
  import Field from '$lib/components/Field.svelte';

  // info — ответ check_lan_conflict: { lan_cidr, wan_cidr, suggest_ip }.
  // onSkip — продолжить без смены (preflight всё равно отметит конфликт).
  // urlToken — токен из ссылки мастера (?token=…), чтобы не вводить руками.
  let { info, urlToken = '', onSkip } = $props();

  // svelte-ignore state_referenced_locally
  let token = $state(urlToken ?? '');
  let error = $state('');
  let busy = $state(false);
  let applied = $state(null); // new_ip после успешного применения

  async function apply() {
    error = '';
    if (token.trim().length === 0) {
      error = 'Введите код установки — он напечатан в терминале после команды установки.';
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

<Card.Root>
  <Card.Header>
    <Card.Title>Конфликт подсетей</Card.Title>
  </Card.Header>

  <Card.Content>
    {#if applied}
      <p class="font-semibold text-success">✓ Новый адрес применён. Сеть роутера перезапускается…</p>
      <ol class="flex list-decimal flex-col gap-2 pl-5">
        <li>Подождите ~15 секунд, пока роутер перезапустит сеть.</li>
        <li>Переподключитесь к роутеру (Wi-Fi/кабель): устройство получит адрес из новой подсети.
          Если не получило — выключите и включите Wi-Fi (или переткните кабель).</li>
        <li>Откройте мастер по новому адресу:
          <strong><a href={`http://${applied}/cheburnet/`}>http://{applied}/cheburnet/</a></strong></li>
      </ol>
    {:else}
      <p>
        Подсеть LAN роутера (<code class="rounded-sm bg-muted px-1 py-0.5 font-mono text-sm">{info.lan_cidr}</code>)
        пересекается с подсетью провайдера
        (<code class="rounded-sm bg-muted px-1 py-0.5 font-mono text-sm">{info.wan_cidr}</code>). Так бывает,
        когда роутер подключён за другим роутером с той же подсетью. Маршрутизация в таком виде
        работать не будет — проверка на следующем шаге установку не пропустит.
      </p>
      <p>
        Решение: сменить адрес LAN на свободный — предлагаем
        <strong>{info.suggest_ip}</strong>. После смены нужно переподключиться к роутеру по
        новому адресу (гайд покажем).
      </p>

      <Field label="Код установки" hint="Смена адреса рвёт соединения — поэтому требует код владельца роутера.">
        <Input type="text" bind:value={token} placeholder="напечатан в терминале после команды установки" />
      </Field>

      {#if error}<p class="text-destructive">{error}</p>{/if}

      <div class="flex flex-wrap gap-3">
        <Button variant="outline" class="min-w-35 flex-1" disabled={busy} onclick={onSkip}>Продолжить без смены</Button>
        <Button class="min-w-35 flex-1" disabled={busy} onclick={apply}>
          {busy ? 'Применяю…' : `Сменить LAN-адрес на ${info.suggest_ip}`}
        </Button>
      </div>
    {/if}
  </Card.Content>
</Card.Root>
