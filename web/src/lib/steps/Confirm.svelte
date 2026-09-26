<script>
  // args — собранные Setup'ом аргументы install (секреты не показываем — только факт наличия).
  // onBack — вернуться поправить; onConfirm — запустить установку. dnsProviders — каталог для метки.
  // Разбор конфигов и метки — чистые tunnelSummary/dnsLabel (logic.js, под vitest).
  import { tunnelSummary, dnsLabel } from '../logic.js';
  import * as Card from '$lib/components/ui/card/index.js';
  import * as Alert from '$lib/components/ui/alert/index.js';
  import Button from '$lib/components/ui/button/button.svelte';
  import StatusIcon from '$lib/components/StatusIcon.svelte';
  import StatusList from '$lib/components/StatusList.svelte';
  import StatusRow from '$lib/components/StatusRow.svelte';

  let { args, onBack, onConfirm, dnsProviders = [] } = $props();
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Проверьте перед установкой</Card.Title>
  </Card.Header>

  <Card.Content>
    <StatusList>
      <StatusRow label="Туннель" value={tunnelSummary(args)} />
      <StatusRow label="Пароль роутера" value="задан" />
      <StatusRow label="Wi-Fi" value={args.ssid ? `${args.ssid} (пароль задан)` : 'не настраивается'} />
      <StatusRow label="Фильтрация (DNS)" value={dnsLabel(args.dns_provider, dnsProviders)} />
      <StatusRow label="Сайты напрямую" value={args.domains.length} />
    </StatusList>

    {#if args.accept_risk}
      <Alert.Root variant="warning">
        <StatusIcon tone="warn" />
        <Alert.Body>
          <Alert.Description>Роутер слабее рекомендуемого — устанавливаем по вашему решению,
            стабильность не гарантируется.</Alert.Description>
        </Alert.Body>
      </Alert.Root>
    {/if}

    <p class="text-muted-foreground">Установка займёт 1–3 минуты. Интернет и Wi-Fi на это время пропадут —
      так и должно быть. <strong class="text-foreground">Не выключайте роутер и не вынимайте кабель.</strong>
      При сбое всё откатится само.</p>

    <div class="flex flex-wrap gap-3">
      <Button variant="outline" class="min-w-35 flex-1" onclick={onBack}>Назад — поправить</Button>
      <Button size="lg" class="min-w-35 flex-1" onclick={onConfirm}>Установить</Button>
    </div>
  </Card.Content>
</Card.Root>
