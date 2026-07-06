---
title: Глоссарий
tags: [reference]
aliases: [glossary, глоссарий, термины]
updated: 2026-06-08
---

# 📖 Глоссарий

Термины проекта в одном месте. Связывай заметки сюда вместо повторных объяснений.

## Сеть и маршрутизация

- **Split-routing / split-tunnel** — раздельная маршрутизация: часть трафика напрямую, часть
  в туннель. → [[split-routing]]
- **Full tunnel** — весь трафик в VPN (режим TRAVEL). → [[home-travel-modes]]
- **Policy routing** — выбор таблицы маршрутизации по правилу (`ip rule`), а не по одному
  default. → [[policy-routing]]
- **fwmark** — метка на пакете (число), по которой `ip rule` выбирает таблицу. → [[policy-routing]]
- **nftset** — именованное множество адресов в nftables; dnsmasq наполняет его при резолве.
  → [[dnsmasq-nftset]]
- **direct** — наше nftset-множество «прямых» адресов (доменов из direct-списка). → [[dnsmasq-nftset]]
- **Kill-switch** — правила, не дающие непрямому трафику утечь в WAN при падении туннеля.
  → [[kill-switch]]

## VPN и DNS

- **AmneziaWG (awg0)** — WireGuard с обфускацией сетевой сигнатуры; интерфейс туннеля. → [[amneziawg]]
- **DPI** — Deep Packet Inspection, анализ содержимого пакетов; обфускация снижает узнаваемость
  сигнатуры протокола.
- **WireGuard** — современный VPN-протокол, основа AmneziaWG.
- **DoH (DNS over HTTPS)** — шифрование DNS внутри HTTPS. → [[encrypted-dns]]
- **https-dns-proxy** — лёгкий демон DoH (замена этой функции sing-box). → [[encrypted-dns]]
- **dnsmasq** — DNS/DHCP-сервер OpenWrt; у нас делает adblock + nftset + форвард в DoH.
- **FakeIP** — приём sing-box (фейковый IP для перехвата); мы его **не** используем.
  → [[0001-why-not-singbox]]
- **adblock-lean** — блокировка рекламы через blocklist'ы в dnsmasq. → [[adblock]]

## Платформа

- **OpenWrt** — Linux-прошивка для роутеров; целевая 25.12+.
- **ucode** — встроенный в OpenWrt JS-подобный язык; на нём наш движок. → [[engine-ucode]]
- **ubus** — шина межпроцессного RPC в OpenWrt; мост UI ↔ движок.
- **uci** — система конфигов OpenWrt (`/etc/config/*`).
- **fw4 / nftables** — фаервол OpenWrt (таблица `inet fw4`).
- **rpcd** — демон, отдающий ubus-методы (наш RPC-обработчик).
- **apk** — пакетный менеджер OpenWrt 25.12+; ставит наш пакет из feed. → [[bootstrap]]
- **feed** — репозиторий пакетов OpenWrt. → [[bootstrap]]
- **OpenWrt SDK** — тулчейн для сборки пакетов под архитектуры. → [[reliability]]
- **ImageBuilder** — сборка готового образа прошивки (опциональный путь).

## Процесс

- **Control-plane / data-plane** — управление (движок, только при настройке) vs путь трафика
  (ядро, постоянно). → [[architecture-overview]]
- **Preflight** — проверка пригодности железа перед установкой. → [[reliability]]
- **Идемпотентность** — повторный запуск без вреда. → [[reliability]]
- **ADR** — Architecture Decision Record, запись решения и причины. → `decisions/`
- **MOC** — Map of Content, заметка-хаб со ссылками. → [[Home]]
- **Strangler-fig** — миграция по кускам без big-bang rewrite. → [[architecture-v2]]
- **Fail-safe** — сбой ведёт в безопасное состояние (у нас — в туннель, не в утечку).
  → [[split-routing]]

## Дальше

- [[Home]] — карта знаний
- [[conventions]] — как устроен vault
