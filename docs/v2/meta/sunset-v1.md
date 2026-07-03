# 🌅 Sunset v1 — чек-лист удаления старой версии

> **Статус:** план. Удаление v1 — **последний** шаг миграции, отдельным коммитом,
> **только после** релиза v2 и прохождения всех гейтов ниже. До тех пор v1 заморожен,
> но живёт (страховка по стратегии strangler-fig).

Этот документ отвечает на вопрос «когда и как безопасно удалить v1, ничего не сломав».
Принцип: **сначала зелёный и зарелиженный v2, потом удаление** — не наоборот.

---

## 🚦 Гейты: удалять v1 нельзя, пока не выполнено ВСЁ

Снимаем галочки сверху вниз. Любая незакрытая — стоп.

- [ ] **Паритет фич v2 ≥ v1.** Всё, что обещано пользователю, работает в v2:
  - [ ] AmneziaWG (Light-тир) — ✅ готово, покрыто `make qemu-v2`.
  - [ ] Кастомный DNS-фильтр (реклама / 18+) — ✅ готово (`steps/doh`, 5 провайдеров).
  - [x] **VLESS+Reality (Full-тир) — НЕ блокер релиза** (решение мейнтейнера 2026-07-03:
        де-скоуп первого релиза, возврат в v2.1). v1 его тоже не имел, так что паритет
        не страдает; код Full-тира в дереве, но мастер его не предлагает и пакет
        cheburnet-full не собирается.
        См. [0004-multi-protocol-tiers](../decisions/0004-multi-protocol-tiers.md).
- [ ] **v2 проверен «живьём».** Зелёные в CI:
  - [ ] `make qemu-v2` (hermetic smoke движка) — ✅ проходит.
  - [ ] `make qemu-install-v2` (DEPENDS + data-plane на реальных сервисах).
  - [ ] Прогон на **реальном роутере** (Beryl AX / Cudy или совместимый):
        bootstrap → install через RPC → HOME и TRAVEL → DNS-фильтр → reboot+steady-state.
  - [ ] Желательно: QEMU-матрица arch (mipsel / aarch64), а не только x86_64.
- [ ] **Дистрибуция настоящая, не плейсхолдер.**
  - [ ] Реальный feed-URL + ключ подписи (убрать `feed.cheburnet.example` из
        `bootstrap/bootstrap.sh`).
  - [ ] Публикация пакета по git-тегу в CI (`package-build` → feed + Release).
  - [ ] Пользователь реально ставит `apk add cheburnet` из feed'а и проходит мастер.
- [ ] **Релиз v2 выпущен** (git-тег + GitHub Release), и прошёл разумный обкаточный
      период без критичных регрессий.
- [ ] **Документация v2 самодостаточна** — `docs/v2/` объясняет всё, что объясняли
      главы v1 (flash OpenWrt, AmneziaWG, split-routing, DNS, kill-switch, режимы,
      troubleshooting). Ничего важного не теряется при удалении старых глав.

---

## 🗑 Что удаляем (после прохождения гейтов)

Один коммит `chore: sunset v1` (или серия логически связанных). Перечень артефактов v1:

**Корень:**
- [ ] `install.sh`, `setup.sh` — v1-инсталляторы.
- [ ] `AGENTS.md` — гид по v1-коду (контент перенести/проверить против `CLAUDE.md`).

**Каталоги v1:**
- [ ] `setup/` — 11 setup-скриптов (`00-prerequisites` … `10-quality`), `install.sh`,
      `manifest.txt`, `post-upgrade.sh`, `README.md`.
- [ ] `lib/` — v1-хелперы (`cheburnet-*.sh`, `install-awg.sh`, `install-podkop.sh`,
      `net-detect.sh`, `podkop-config.sh`, `family-filter.sh`).
- [ ] `scripts/` — рантайм-скрипты v1 (`awg-watchdog`, `dns-*`, `vpn-mode`, `hotplug`,
      `conntrack-*`, `sqm-tune`, `net-benchmark`, `log-snapshot`, `install-via-tether.sh`).
- [ ] `configs/` — примеры конфигов v1 (podkop/adblock/awg/wireless/sysupgrade).
- [ ] `vendor/` — vendored-инсталляторы podkop/abl (структурный долг ручного обновления).
- [ ] `backup/` — `backup.sh` / `restore.sh` (если не переосмыслены под v2).
- [ ] `web/` — монолитный `index.html` v1 + `rpcd-cheburnet` v1 (заменён на `web-v2/`).
- [ ] `assets/` — проверить, что не используется v2; иначе оставить.

**Тесты v1 (bats):**
- [ ] `tests/unit/*.bats` — 4 файла (v1 pure-функции).
- [ ] `tests/integration/*.bats` + `helpers/` + `mocks/` — 10 файлов (моки v1 rpcd).
- [ ] `tests/qemu/smoke.sh`, `smoke-http.sh`, `install.sh`, `audit-setup.sh` — v1 QEMU.
  - ⚠️ **Оставить** `smoke-v2.sh`, `install-v2.sh`, `lib.sh` — это v2.

**Документация v1:**
- [ ] `docs/00-flash-openwrt.md` … `docs/10-upgrades.md`, `docs/01-architecture.md`,
      `docs/03-podkop-routing.md`, `docs/04-adblock.md` — главы про podkop/sing-box.
  - ⚠️ Сверить с `docs/v2/`: если глава v1 объясняет что-то, чего нет в v2 — сначала
        перенести, потом удалять.
- [ ] `docs/RELEASE-CHECKLIST.md` — заменить на v2-версию (или обновить).

**CI:**
- [ ] Job'ы `qemu-smoke` / `qemu-install` (v1) в `.github/workflows/test.yml` —
      удалить после того, как v2-аналоги стабильны в CI.
- [ ] `make` цели `qemu`, `qemu-http`, `qemu-install`, `test-unit`, `test-integration`
      (v1) — вычистить из `Makefile`.

---

## ✅ После удаления

- [ ] `make lint && make test-engine && make qemu-v2` — зелёные.
- [ ] `grep -ri "podkop\|sing-box\|setup/\|install.sh" --include='*.md' docs/` — нет
      висячих ссылок на удалённое.
- [ ] `README.md` описывает только v2-путь установки.
- [ ] Обновить `CLAUDE.md`: убрать раздел «миграция v1→v2», снять упоминания AGENTS.md.

---

## 🧭 Порядок (кратко)

```
qemu-v2 + qemu-install-v2 зелёные в CI
  → проверка на реальном роутере
    → настоящий feed + подпись + публикация по тегу
      → РЕЛИЗ v2 (тег + Release, только Light-тир — Full отложен на v2.1)
        → обкатка без критичных регрессий
          → chore: sunset v1 (этот чек-лист)
```
