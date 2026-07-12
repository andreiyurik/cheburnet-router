# cheburnet-router — test targets
#
# Уровни тестов:
#   make lint             — T1: статика (shellcheck + sh -n + JSON).
#   make test-engine      — T2: юниты движка (чистая логика на ucode, host-only, секунды).
#   make poc-split        — Фаза 0 PoC: split-routing на примитивах в netns.
#   make qemu-v2          — T3a: hermetic VM smoke движка в qemu/KVM (~2мин, без интернета).
#   make qemu-webui-v2    — T3b: VM smoke с HTTP/ubus через uhttpd + UI (~3мин, нужен интернет).
#   make qemu-install-v2  — T3c: DEPENDS + data-plane против реальных сервисов (~5-8мин,
#                            нужен интернет). Release-gate.

.PHONY: lint test-engine test-shell poc-split qemu-v2 qemu-webui-v2 qemu-install-v2 qemu-reality-v2

lint:
	@bash tests/lint.sh

# Юнит-тесты движка (чистая логика на ucode, секунды, без роутера).
test-engine:
	@sh engine/run-tests.sh

# Тесты shell-скриптов роутера с изоляцией через фейки (без сети/пакетов): ретраи/код
# выхода install-singbox.sh (кнопка Full-тира) — самое глючеопасное место.
test-shell:
	@bash tests/install-singbox-test.sh

# Фаза 0 PoC + e2e: split-routing на примитивах И из реального вывода генератора,
# прогон через network namespace. Нужны nft/ip/unshare; ucode — для фазы B.
poc-split:
	@unshare -rn sh tests/poc/split-routing-netns.sh

# T3a-v2 — hermetic VM smoke для движка v2 (ucode). Деплоит движок как пакет
# (shim + engine без tests/, ACL из реестра) и проверяет на живом OpenWrt:
# ubus-методы, границу доверия сквозь rpcd, rootpass→session.login,
# family on/off на реальном uci, NAT-зону + nft-цепочки + teardown на реальном fw4.
qemu-v2:
	@./tests/qemu/smoke-v2.sh

# T3c-v2 — установка зависимостей через apk + data-plane против РЕАЛЬНЫХ сервисов
# (dnsmasq-full/https-dns-proxy). Единственная проверка DEPENDS пакета из живого
# feed'а. Нужен интернет для apk. ~5-8 мин с KVM.
qemu-install-v2:
	@./tests/qemu/install-v2.sh

# T3b-v2 — HTTP-слой веб-мастера v2: uhttpd раздаёт Svelte-бандл, /ubus
# JSON-RPC (путь браузера), ACL anon-vs-admin, session.login, handler-валидация
# без деструктивных эффектов. Нужен интернет в VM (apk add uhttpd-mod-ubus).
qemu-webui-v2:
	@./tests/qemu/webui-v2.sh

# T3d-v2 — Full-тир (VLESS+Reality) data-plane WIRING на живом OpenWrt: singbox-шаг
# применяет config.json + netifd-маршрут singtun0 (half-routes), connectivity-probe
# корректно отвергает недостижимый сервер (fail-safe), teardown чистит. Рабочий
# Reality-сервер НЕ нужен (герметично). Нужен интернет для apk. ~4-6 мин с KVM.
qemu-reality-v2:
	@./tests/qemu/reality-v2.sh
