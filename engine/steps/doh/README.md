# engine/steps/doh — шифрованный DNS (DoH) через https-dns-proxy

Шифрует upstream-резолв лёгким `https-dns-proxy` перед dnsmasq — замена DoH, который в v1
нёс sing-box ([encrypted-dns](../../../docs/v2/concepts/encrypted-dns.md)). По умолчанию
**Quad9** (no-log, блокирует malware) + **Cloudflare** как fallback.

## Почему DoH на роутере, а не на клиенте

Централизованный DNS на роутере сохраняет [пометку адресов](../../../docs/v2/concepts/dnsmasq-nftset.md)
для split-routing и [adblock](../../../docs/v2/concepts/adblock.md). Клиентский DoH (Chrome,
смарт-ТВ) их ломает — роутер не видит резолв. Цепочка одна: dnsmasq (adblock + nftset) →
https-dns-proxy (:5053/:5054) → зашифрованно в Quad9/Cloudflare.

## dnsmasq-привязку держим САМИ (не магия пакета)

Пакет умеет авто-править dnsmasq (`update_dnsmasq_config='*'`) — мы это **отключаем** (`-`) и
прописываем upstream `server` сами. Так один владелец конфига dnsmasq и виден каждый шаг
(учебная цель). `noresolv='1'` ставит [DNS-шаг](../dns/) — без него dnsmasq утёк бы в
ISP-`resolv.conf`; вместе эти два шага = «весь DNS только через наш DoH».

## Чистое ядро vs импурный apply

- **`doh.uc`** — `build_doh_plan(current, opts)` → uci-операции для https-dns-proxy + dnsmasq.
  **Чистая функция**, тесты — [tests/](tests/).
- **`apply.uc`** — **router-side**: читает текущие секции/server из uci, применяет (delete
  `|| true` → `uci batch` → commit → restart https-dns-proxy + reload dnsmasq). QEMU.
- **`plan.uc`** — CLI чистого ядра: current-снимок (stdin) → операции, без применения.

## Идемпотентность

- **https-dns-proxy секции** — пересоздаём (delete-before-set). Сносим **все** существующие
  (включая дефолтную секцию пакета на :5053) — иначе она конфликтует с нашей по порту. Секции
  именованные (`quad9`/`cloudflare`) → дружелюбны к `uci batch`.
- **dnsmasq `server`** — минимальный diff по **нашим** записям (`127.0.0.1#<порт>`): чужие
  upstream-серверы пользователя не трогаем. Повтор при настроенном состоянии → no-op.

## Использование

```sh
echo '{"current":{"hdp_sections":["cfg01"],"servers":[]}}' | ucode -R engine/steps/doh/plan.uc
ucode -R engine/steps/doh/apply.uc --dry-run   # на роутере: читает uci сам
```

## Граница и честность

Схема uci `https-dns-proxy` (опции `listen_addr/listen_port/resolver_url/bootstrap_dns` и
секция `config` типа `main` с `update_dnsmasq_config`) — по стабильному пакету OpenWrt; точную
привязку проверяем в QEMU. Выбор резолверов — настройка (`opts.resolvers`), не зашитый выбор.

## Тесты

`make test-engine`. Покрыто: дефолтные резолверы, `update_dnsmasq_config='-'`, dnsmasq server
(чистая система / идемпотентный no-op / чужой upstream сохраняется), замена дефолтной секции
пакета, кастомные резолверы, валидация (пустой список / дубль порта).
