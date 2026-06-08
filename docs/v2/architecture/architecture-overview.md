---
title: Архитектура — обзор слоёв
tags: [architecture]
aliases: [architecture-overview, обзор-архитектуры]
updated: 2026-06-08
---

# 🏗 Архитектура — обзор слоёв

> [!tip] TL;DR
> Четыре слоя: тонкий [[bootstrap|bootstrap]] (shell) → [[engine-ucode|движок]] (ucode) →
> [[data-plane|data-plane]] (ядро: dnsmasq + nftables + awg) → [[web-wizard|веб-мастер]]
> (Svelte). Полный дизайн — [[architecture-v2]].

## Карта слоёв

```mermaid
flowchart TB
    subgraph control["Control-plane (управление)"]
        boot[bootstrap<br/>тонкий shell] --> engine[движок<br/>ucode]
        engine --> ubus[ubus/rpcd]
    end
    subgraph data["Data-plane (трафик)"]
        dnsmasq --> proxy[https-dns-proxy]
        nft[nftables] --> awg[awg0]
    end
    subgraph ui["UI"]
        wizard[веб-мастер Svelte]
    end
    engine -->|настраивает| dnsmasq & nft & awg
    wizard -->|ubus RPC| ubus
    ubus --> engine
```

## Кто за что отвечает

| Слой | Технология | Заметка | Роль |
|---|---|---|---|
| Bootstrap | shell (~30 строк) | [[bootstrap]] | добавить feed → `apk add` → открыть мастер |
| Движок | ucode | [[engine-ucode]] | preflight, шаги, генерация конфигов, ubus |
| Data-plane | dnsmasq, nftables, awg, https-dns-proxy | [[data-plane]] | через что реально идёт трафик |
| UI | Svelte | [[web-wizard]] | мастер настройки в браузере |

## Control-plane vs data-plane

Важное разделение для понимания:

- **Control-plane** (движок) работает **только при установке/изменении настроек**. Настроил —
  он молчит. Не висит в data-path.
- **Data-plane** (ядро) работает **постоянно**, но это нативные механизмы Linux — без
  пользовательских демонов в пути пакета. Поэтому легко и надёжно.

> [!note] Почему это даёт надёжность и лёгкость
> В рантайме трафик обрабатывает только ядро. Нет процесса, который «упадёт и всё сломается».
> Движок может вообще не запускаться неделями — система работает. См. [[reliability]].

## Дальше

- [[data-plane]] — детально про плоскость данных
- [[engine-ucode]] — детально про движок
- [[reliability]] — паттерны надёжности
- [[architecture-v2]] — полный дизайн-документ
