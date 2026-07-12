# 📚 Документация cheburnet-router

## Архитектура и база знаний

- 📐 **[architecture-v2.md](architecture-v2.md)** — полный дизайн-документ: лёгкий split-tunnel
  на примитивах ядра, движок на ucode, дистрибуция через GitHub Releases + apk.
- 🧠 **[База знаний (Obsidian-vault)](v2/README.md)** — образовательная документация «от первых
  принципов»: как работает [split-routing](v2/concepts/split-routing.md),
  [DNS и маршрутизация](v2/concepts/dns-and-routing.md),
  [policy routing](v2/concepts/policy-routing.md), и почему приняты ключевые
  [решения (ADR)](v2/decisions/0001-why-not-singbox.md). Точка входа —
  [v2/Home.md](v2/Home.md).

> Для AI-ассистентов и контрибьюторов: гид по проекту — `CLAUDE.md` в корне репозитория.

## Установка

- **[00 · Прошивка OpenWrt](00-flash-openwrt.md)** — первая установка OpenWrt на роутер, нужна
  один раз перед основной установкой.
- **[open-terminal.md](open-terminal.md)** — как открыть терминал и вставить команду установки
  (для тех, кто впервые видит терминал).
- **[install-no-ssh.md](install-no-ssh.md)** — установка через браузер (LuCI), без SSH.
- **[install-blocked.md](install-blocked.md)** — что делать, если провайдер блокирует загрузку
  пакетов при установке.

## Справочные

- **[v2/reference/troubleshooting.md](v2/reference/troubleshooting.md)** — куда смотреть, когда
  что-то не работает.
- **[v2/reference/hardware-requirements.md](v2/reference/hardware-requirements.md)** — какое
  железо подходит.
- **[v2/meta/release-checklist.md](v2/meta/release-checklist.md)** — ручная проверка перед тегом.
- **[education.md](education.md)** — лабораторные работы о том, как устроена сеть.
- **[support.md](support.md)** — как поддержать проект.
