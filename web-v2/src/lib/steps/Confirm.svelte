<script>
  // args — собранные Setup'ом аргументы install (секреты не показываем — только факт наличия).
  // onBack — вернуться поправить; onConfirm — запустить установку. dnsProviders — каталог для метки.
  let { args, onBack, onConfirm, dnsProviders = [] } = $props();

  // Первая строка [Peer]→Endpoint — единственное, что безопасно показать из AWG-конфига.
  function endpoint(conf) {
    const m = (conf ?? '').match(/^\s*Endpoint\s*=\s*(.+)$/m);
    return m ? m[1].trim() : '—';
  }

  // Краткая сводка туннеля без секретов: протокол + хост сервера.
  function tunnelSummary() {
    if (args.protocol === 'reality') {
      const m = (args.reality_conf ?? '').match(/@([^?#/]+)/); // host:port после uuid@
      return m ? `VLESS+Reality → ${m[1]}` : 'VLESS+Reality';
    }
    return `AmneziaWG → ${endpoint(args.awg_conf)}`;
  }

  // Человекочитаемая метка фильтрации по выбранному id (или дефолт-описание).
  function dnsLabel(id) {
    const p = dnsProviders.find((x) => x.id === id);
    return p ? `${p.name} — ${p.description}` : (id ?? 'по умолчанию');
  }
</script>

<section>
  <h2>Проверьте перед установкой</h2>

  <ul class="status">
    <li><span>Туннель</span><strong>{tunnelSummary()}</strong></li>
    <li><span>Пароль роутера</span><strong>задан</strong></li>
    {#if args.ssid}
      <li><span>Wi-Fi</span><strong>{args.ssid} (пароль задан)</strong></li>
    {:else}
      <li><span>Wi-Fi</span><strong>не настраивается</strong></li>
    {/if}
    <li><span>Фильтрация (DNS)</span><strong>{dnsLabel(args.dns_provider)}</strong></li>
    <li><span>Свои домены прямого доступа</span><strong>{args.domains.length}</strong></li>
  </ul>

  <p class="muted">
    Установка займёт несколько минут: пакеты, туннель, шифрованный DNS, firewall. При сбое
    изменения откатятся автоматически.
  </p>

  <div class="row">
    <button onclick={onBack}>Назад — поправить</button>
    <button class="primary" onclick={onConfirm}>Установить</button>
  </div>
</section>
