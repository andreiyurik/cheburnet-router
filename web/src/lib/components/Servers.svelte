<script>
  // Сохранённые AWG-серверы («страны»): список с приоритетом, ручной выбор, автосмена (engine/profiles).
  // Переключение — фоновая замена сервера с автооткатом; прогресс — общий канал install_progress.
  import { onDestroy } from 'svelte';
  import { cheburnet, isAccessDenied } from '../ubus.js';
  import { checkConf, moveProfile, lastSwitchText } from '../logic.js';
  import Button from '$lib/components/ui/button/button.svelte';
  import Input from '$lib/components/ui/input/input.svelte';
  import Textarea from '$lib/components/ui/textarea/textarea.svelte';
  import Checkbox from '$lib/components/ui/checkbox/checkbox.svelte';
  import Badge from '$lib/components/ui/badge/badge.svelte';
  import Spinner from '$lib/components/ui/spinner/spinner.svelte';
  import Field from '$lib/components/Field.svelte';
  import ConfCheck from '$lib/components/ConfCheck.svelte';

  // protocol — активный туннель (status.protocol); onDenied — открыть вход; onChanged — обновить статус.
  let { loggedIn, protocol, onDenied, onChanged } = $props();

  let list = $state(null);       // ответ list_profiles
  let loadError = $state('');
  let busy = $state(false);
  let note = $state('');
  let switching = $state('');    // id сервера, на который сейчас переключаемся
  let timer = null;

  let adding = $state(false);
  let newName = $state('');
  let newConf = $state('');
  let editId = $state('');       // сервер, открытый на правку
  let editName = $state('');
  let editConf = $state('');

  const nowSec = () => Math.floor(Date.now() / 1000);
  const nameOf = (id) => list?.profiles.find((p) => p.id === id)?.name ?? '';

  async function load() {
    try {
      list = await cheburnet('list_profiles');
      loadError = '';
    } catch (e) {
      if (isAccessDenied(e)) onDenied();
      else loadError = e.message;
    }
  }

  // act(fn) — синхронная правка списка; ответ метода — новый список.
  async function act(fn, ok = '') {
    busy = true;
    note = '';
    try {
      list = await fn();
      note = ok;
      return true;
    } catch (e) {
      if (isAccessDenied(e)) onDenied();
      else note = e.message;
      return false;
    } finally {
      busy = false;
    }
  }

  async function readFile(e, set) {
    const f = e.target.files?.[0];
    if (f) set(await f.text());
  }

  async function addProfile() {
    const bad = checkConf('awg', newConf);
    if (bad) { note = bad; return; }
    const name = newName.trim();
    if (await act(() => cheburnet('add_profile', { name, awg_conf: newConf.trim() + '\n' }), `Сервер «${name}» сохранён.`)) {
      adding = false; newName = ''; newConf = '';
    }
  }

  function openEdit(p) {
    editId = editId === p.id ? '' : p.id;
    editName = p.name;
    editConf = '';
  }

  async function saveEdit(p) {
    if (editName.trim() !== p.name &&
        !(await act(() => cheburnet('rename_profile', { id: p.id, name: editName.trim() }), 'Название сохранено.')))
      return;
    if (editConf.trim()) {
      const bad = checkConf('awg', editConf);
      if (bad) { note = bad; return; }
      if (p.active) {
        // Подключённый сервер: новый конфиг проверяется на живом туннеле, при сбое — откат.
        await startSwitch(p.id, () => cheburnet('update_profile_conf', { id: p.id, awg_conf: editConf.trim() + '\n' }));
      } else if (!(await act(() => cheburnet('update_profile_conf', { id: p.id, awg_conf: editConf.trim() + '\n' }), 'Конфиг заменён.'))) {
        return;
      }
    }
    editId = '';
  }

  function remove(p) {
    if (!confirm(`Удалить сервер «${p.name}»? Его конфиг будет стёрт с роутера.`)) return;
    act(() => cheburnet('delete_profile', { id: p.id }), `Сервер «${p.name}» удалён.`);
  }

  function move(p, delta) {
    const ids = moveProfile(list.profiles.map((q) => q.id), p.id, delta);
    act(() => cheburnet('order_profiles', { ids }));
  }

  // setAuto(el) — галочка не привязана к list (односторонняя), и Svelte не перерисует проп, если
  // list.auto не изменился: при отказе возвращаем её к состоянию роутера сами.
  async function setAuto(el) {
    const enabled = el.checked;
    const ok = await act(() => cheburnet('set_failover', { enabled }),
      enabled ? 'Автосмена включена.' : 'Автосмена выключена — сервер меняете только вы.');
    if (!ok) el.checked = !enabled;
  }

  // startSwitch(id, call) — фоновая операция с откатом: ждём done в install_progress.
  async function startSwitch(id, call) {
    busy = true;
    note = '';
    switching = id;
    try {
      await call();
      timer = setInterval(poll, 2000);
    } catch (e) {
      busy = false;
      switching = '';
      if (isAccessDenied(e)) onDenied();
      else note = e.message;
    }
  }

  async function poll() {
    try {
      const p = await cheburnet('install_progress');
      if (!p.done) return;
      clearInterval(timer); timer = null;
      const name = nameOf(switching);
      note = p.result === 'ok'
        ? `Подключён «${name}» — трафик идёт через него.`
        : `Сервер «${name}» не ответил — прежний подключён обратно. Проверьте, что конфиг свежий и сервер жив.`;
      busy = false;
      switching = '';
      await load();
      onChanged();
    } catch (e) {
      // Сессия протухла посреди переключения: опрос сам не кончится, а кнопки так и остались бы серыми.
      if (!isAccessDenied(e)) return; // роутер на секунду пропал при перезапуске сети — следующий опрос
      clearInterval(timer); timer = null;
      busy = false;
      switching = '';
      note = 'Нужен вход — после него обновите список: переключение на роутере доработает само.';
      onDenied();
    }
  }

  $effect(() => { if (loggedIn) load(); });
  onDestroy(() => { if (timer) clearInterval(timer); });
</script>

{#if !loggedIn}
  <p class="text-sm text-muted-foreground">Сохранённые серверы видны после входа ·
    <Button variant="link" onclick={onDenied}>Войти</Button></p>
{:else if loadError}
  <p class="text-sm text-destructive">Не удалось загрузить список серверов: {loadError}</p>
  <Button class="mt-2" variant="outline" size="sm" onclick={load}>Повторить</Button>
{:else if !list}
  <p class="flex items-center gap-2 text-sm text-muted-foreground"><Spinner /> Загружаю список серверов…</p>
{:else}
  <p class="mb-3 text-sm text-muted-foreground">Конфиги серверов в разных странах — переключение в одно нажатие.
    Не отзовётся новый — вернётся прежний.</p>

  {#if list.profiles.length === 0}
    <p class="text-sm">Сохранённых серверов пока нет.
      {#if protocol === 'awg'}Текущий появится здесь после следующей замены конфига — или добавьте его кнопкой ниже.{/if}</p>
  {:else}
    <ol data-slot="profiles" class="flex flex-col divide-y divide-border rounded-lg border border-border">
      {#each list.profiles as p, i (p.id)}
        <li class="p-3">
          <div class="flex flex-wrap items-center gap-2">
            <span class="w-5 text-xs text-muted-foreground">{i + 1}.</span>
            <span class="font-semibold">{p.name}</span>
            {#if p.active}<Badge variant="success">подключён</Badge>{/if}
            {#if switching === p.id}<span class="flex items-center gap-1 text-sm text-muted-foreground"><Spinner /> проверяю…</span>{/if}
            <span class="ml-auto flex gap-1">
              <Button variant="ghost" size="sm" aria-label="Выше по приоритету" disabled={busy || i === 0} onclick={() => move(p, -1)}>↑</Button>
              <Button variant="ghost" size="sm" aria-label="Ниже по приоритету" disabled={busy || i === list.profiles.length - 1} onclick={() => move(p, 1)}>↓</Button>
            </span>
          </div>
          <div class="mt-2 flex flex-wrap gap-2 pl-7">
            {#if !p.active}
              <Button variant="outline" size="sm" disabled={busy}
                      onclick={() => startSwitch(p.id, () => cheburnet('activate_profile', { id: p.id }))}>Подключить</Button>
            {/if}
            <Button variant="outline" size="sm" disabled={busy} onclick={() => openEdit(p)}>Изменить</Button>
            {#if !p.active}
              <Button variant="destructive-outline" size="sm" disabled={busy} onclick={() => remove(p)}>Удалить</Button>
            {/if}
          </div>
          {#if editId === p.id}
            <div class="mt-3 flex flex-col gap-3 pl-7">
              <Field label="Название"><Input bind:value={editName} maxlength="32" disabled={busy} /></Field>
              <Field label="Новый конфиг" optional hint={p.active ? 'Сервер подключён: новый конфиг проверим на живом туннеле, не ответит — останется прежний.' : ''}>
                <Textarea bind:value={editConf} rows="4" class="font-mono" disabled={busy} placeholder="[Interface]…" />
                {#if editConf.trim()}<ConfCheck id="awg" text={editConf} />{/if}
              </Field>
              <Field label="…или загрузить файлом">
                <Input type="file" accept=".conf,text/plain" disabled={busy} onchange={(e) => readFile(e, (t) => (editConf = t))} />
              </Field>
              <div><Button variant="outline" disabled={busy || !editName.trim()} onclick={() => saveEdit(p)}>Сохранить</Button></div>
            </div>
          {/if}
        </li>
      {/each}
    </ol>
  {/if}

  {#if lastSwitchText(list.last_switch, nowSec())}
    <p class="mt-3 text-sm">{lastSwitchText(list.last_switch, nowSec())}</p>
  {/if}

  {#if list.profiles.length >= 2}
    <label class="mt-4 flex items-start gap-3">
      <Checkbox checked={list.auto} disabled={busy} onchange={(e) => setAuto(e.currentTarget)} />
      <span class="text-sm">Переключаться самому, если сервер не отвечает 15 минут.
        <span class="block text-muted-foreground">Пробует следующие по порядку списка и остаётся на том, что заработал.
          Если пропал сам домашний интернет — ничего не трогает.</span></span>
    </label>
  {/if}

  {#if adding}
    <div class="mt-4 flex flex-col gap-3">
      <Field label="Название" hint="Например, страна или город сервера."><Input bind:value={newName} maxlength="32" disabled={busy} /></Field>
      <Field label="Конфиг AmneziaWG">
        <Textarea bind:value={newConf} rows="5" class="font-mono" disabled={busy} placeholder="[Interface]…" />
        <ConfCheck id="awg" text={newConf} />
      </Field>
      <Field label="…или загрузить файлом">
        <Input type="file" accept=".conf,text/plain" disabled={busy} onchange={(e) => readFile(e, (t) => (newConf = t))} />
      </Field>
      <div class="flex gap-2">
        <Button variant="outline" disabled={busy || !newName.trim() || !newConf.trim()} onclick={addProfile}>Сохранить сервер</Button>
        <Button variant="ghost" disabled={busy} onclick={() => (adding = false)}>Отмена</Button>
      </div>
    </div>
  {:else if list.profiles.length < list.max}
    <Button class="mt-4" variant="outline" disabled={busy} onclick={() => (adding = true)}>+ Добавить сервер</Button>
  {:else}
    <p class="mt-4 text-sm text-muted-foreground">Сохранено максимум — {list.max} серверов. Чтобы добавить новый, удалите лишний.</p>
  {/if}

  {#if note}<p data-slot="action-note" class="mt-3 text-muted-foreground">{note}</p>{/if}
{/if}
