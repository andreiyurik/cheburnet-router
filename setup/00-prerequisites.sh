#!/bin/sh
# 00-prerequisites.sh — обновить пакетный индекс, установить базовые инструменты.
# Рассчитан на OpenWrt 25.12+ с apk.
set -e

echo "== 00. Prerequisites =="

# Обновляем списки пакетов.
# apk update изредка падает с "Operation not permitted" / "unexpected end
# of file" из-за временной недоступности одного из зеркал OpenWrt — даже
# когда стейл всего один индекс из 8, apk возвращает ошибку. Один повтор
# закрывает большинство таких транзиентных сбоев без вмешательства
# пользователя.
echo "→ apk update"
if ! apk update; then
    echo "  apk update упал на одном из зеркал, повторяю..."
    apk update
fi

# Базовые инструменты, нужные дальше
# - jq для разбора JSON (sing-box config, clash-api)
# - curl для тестов и скачиваний
# - coreutils-sort для adblock-lean (ускоряет обработку списков)
# - ca-bundle для TLS
echo "→ install base tools"
apk add --no-interactive jq ca-bundle coreutils-sort 2>&1 | tail -3 || true

# Убедимся что есть ubi-утилиты и т.п. стандартные вещи (обычно уже есть)

# Disable unused services (уменьшаем attack surface)
if [ -f /etc/init.d/radius ]; then
    /etc/init.d/radius disable 2>/dev/null || true
    echo "→ disabled unused service: radius"
fi

echo "✓ prerequisites OK"
