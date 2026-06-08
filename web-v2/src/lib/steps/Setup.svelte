<script>
  // onSubmit(args) — args для метода install движка: { awg_conf, domains, token }.
  // onBack — вернуться на preflight.
  let { onSubmit, onBack } = $props();

  let awgConf = $state('');
  let domainsText = $state('');
  let token = $state('');
  let error = $state('');

  // Загрузка AWG-конфига файлом (вставить нормису тяжело — даём три пути: файл/вставка/—).
  async function onFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    awgConf = await f.text();
  }

  // Direct-домены: по строке или через запятую → массив. Пустые/пробелы отбрасываем
  // (движок всё равно валидирует и отбрасывает мусор — fail-safe, см. routing.build_plan).
  function parseDomains(text) {
    return text
      .split(/[\s,]+/)
      .map((d) => d.trim())
      .filter((d) => d.length > 0);
  }

  function submit() {
    error = '';
    if (awgConf.trim().length === 0) {
      error = 'Вставьте или загрузите AWG-конфиг.';
      return;
    }
    if (token.trim().length === 0) {
      error = 'Введите install-токен (его напечатал bootstrap по SSH).';
      return;
    }
    onSubmit({
      awg_conf: awgConf,
      domains: parseDomains(domainsText),
      token: token.trim(),
    });
  }
</script>

<section>
  <h2>Настройка</h2>

  <label>
    <span>AWG-конфиг провайдера</span>
    <textarea
      bind:value={awgConf}
      rows="8"
      placeholder="[Interface]&#10;PrivateKey = …&#10;Address = …&#10;[Peer]&#10;PublicKey = …&#10;Endpoint = host:port"
    ></textarea>
  </label>
  <label class="file">
    <span>…или загрузить файлом</span>
    <input type="file" accept=".conf,text/plain" onchange={onFile} />
  </label>

  <label>
    <span>Домены прямого доступа <em>(необязательно)</em></span>
    <textarea
      bind:value={domainsText}
      rows="3"
      placeholder="example.com&#10;example.org"
    ></textarea>
    <small class="muted">Эти домены идут напрямую; весь остальной трафик — через туннель.</small>
  </label>

  <label>
    <span>Install-токен</span>
    <input type="text" bind:value={token} placeholder="из вывода bootstrap по SSH" />
  </label>

  <p class="muted">
    Wi-Fi и пароль роутера пока настраиваются отдельно — соответствующие шаги движка ещё впереди.
  </p>

  {#if error}<p class="warn">{error}</p>{/if}

  <div class="row">
    <button onclick={onBack}>Назад</button>
    <button class="primary" onclick={submit}>Установить</button>
  </div>
</section>
