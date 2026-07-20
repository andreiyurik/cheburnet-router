<script>
  // args — собранные Setup'ом аргументы install (секреты не показываем — только факт наличия).
  // onBack — вернуться поправить; onConfirm — запустить установку. dnsProviders — каталог для метки.
  // Разбор конфигов и метки — чистые tunnelSummary/dnsLabel (logic.js, под vitest).
  import { tunnelSummary, dnsLabel } from '../logic.js';

  let { args, onBack, onConfirm, dnsProviders = [] } = $props();
</script>

<section>
  <h2>Проверьте перед установкой</h2>

  <ul class="status">
    <li><span>Туннель</span><strong>{tunnelSummary(args)}</strong></li>
    <li><span>Пароль роутера</span><strong>задан</strong></li>
    {#if args.ssid}
      <li><span>Wi-Fi</span><strong>{args.ssid} (пароль задан)</strong></li>
    {:else}
      <li><span>Wi-Fi</span><strong>не настраивается</strong></li>
    {/if}
    <li><span>Фильтрация (DNS)</span><strong>{dnsLabel(args.dns_provider, dnsProviders)}</strong></li>
    <li><span>Сайты напрямую, без VPN</span><strong>{args.domains.length}</strong></li>
  </ul>

  <p class="muted">
    Установка займёт несколько минут: пакеты, туннель, шифрованный DNS, firewall. При сбое
    изменения откатятся автоматически.
  </p>

  <p class="note">
    📶 Во время настройки интернет и Wi-Fi на несколько минут пропадут — это часть установки,
    так и должно быть. <strong>Не выключайте роутер и не вынимайте кабель</strong> — связь
    вернётся сама, даже если что-то пойдёт не так.
  </p>

  <div class="row">
    <button onclick={onBack}>Назад — поправить</button>
    <button class="primary" onclick={onConfirm}>Установить</button>
  </div>
</section>
