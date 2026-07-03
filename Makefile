# cheburnet-router — test targets
#
# Уровни тестов:
#   make lint        — T1: статика (shellcheck + sh -n + JSON + SHA-sync).
#   make test        — T2: unit + mock-integration на bats (host-only, ~10с).
#   make qemu        — T3a: hermetic VM smoke в qemu/KVM (~90с, без интернета).
#   make qemu-http   — T3b: VM smoke с HTTP/ubus + UI-кнопками (~3мин, нужен
#                     интернет в VM для apk add uhttpd-mod-ubus).
#   make qemu-install — T3c: полный прогон setup/install.sh на VM (~5-10мин,
#                     нужен интернет — apk + github для podkop/adblock).
#                     Release-gate. Поймал uci/busybox-несовместимости,
#                     которые mock-тесты T2 пропускают.

.PHONY: lint test test-unit test-integration qemu qemu-v2 qemu-http qemu-webui-v2 qemu-install qemu-install-v2 hardware \
        test-engine poc-split

BATS := tests/vendor/bats-core/bin/bats

lint:
	@bash tests/lint.sh

# test = unit + integration. Оба гоняются на bats-core, разница только в том,
# что integration source'ит реальный web/rpcd-cheburnet через PATH-mock'и
# (uci, ubus, awg, jsonfilter, nslookup и т.п.) против fake rootfs.
test: test-unit test-integration

test-unit:
	@if [ ! -x "$(BATS)" ]; then \
		echo "✗ bats-core не найден в tests/vendor/bats-core/"; \
		echo "  Запустите: git submodule update --init --recursive"; \
		exit 1; \
	fi
	@$(BATS) tests/unit/

test-integration:
	@if [ ! -x "$(BATS)" ]; then \
		echo "✗ bats-core не найден"; exit 1; \
	fi
	@$(BATS) tests/integration/

# ── v2 (движок на ucode) ────────────────────────────────────────────────────
# Отдельно от v1-таргетов: ucode-движок строится по фазам (см. docs/architecture-v2.md),
# параллельно живому v1. Эти таргеты host-only и не требуют bats/QEMU.

# Юнит-тесты движка (чистая логика на ucode, секунды, без роутера).
test-engine:
	@sh engine/run-tests.sh

# Фаза 0 PoC + e2e: split-routing на примитивах И из реального вывода генератора,
# прогон через network namespace. Нужны nft/ip/unshare; ucode — для фазы B.
poc-split:
	@unshare -rn sh tests/poc/split-routing-netns.sh

# T3a — hermetic. Поднимает свежий OpenWrt snapshot в qemu/KVM, кладёт наш
# rpcd-handler через ssh+cat (без apk, без интернета), проверяет что ubus
# отвечает корректным JSON. Ловит регрессии типа gawk-vs-busybox-awk и
# busybox-ash несовместимостей, которые mock-уровень T2 не видит.
qemu:
	@./tests/qemu/smoke.sh

# T3a-v2 — hermetic VM smoke для ДВИЖКА v2 (ucode). Деплоит движок как пакет
# (shim + engine без tests/, ACL из реестра) и проверяет на живом OpenWrt:
# 14 ubus-методов, границу доверия сквозь rpcd, rootpass→session.login,
# family on/off на реальном uci, NAT-зону + nft-цепочки + teardown на реальном fw4.
qemu-v2:
	@./tests/qemu/smoke-v2.sh

# T3c-v2 — установка зависимостей через apk + data-plane против РЕАЛЬНЫХ сервисов
# (dnsmasq-full/https-dns-proxy). Единственная проверка DEPENDS пакета из живого
# feed'а. Нужен интернет для apk. ~5-8 мин с KVM.
qemu-install-v2:
	@./tests/qemu/install-v2.sh

# T3b — расширенный. Дополнительно ставит uhttpd-mod-ubus (apk update/add —
# нужен интернет!) и тестирует то, что РЕАЛЬНО делают кнопки в UI: HTTP-POST
# на /ubus с JSON-RPC, ACL anon-vs-authed, handler-валидация без destructive
# побочных эффектов (factory_reset с неправильным confirm, mode_switch
# c invalid mode и т.п.).
qemu-http:
	@./tests/qemu/smoke-http.sh

# T3b-v2 — HTTP-слой веб-мастера v2: uhttpd раздаёт Svelte-бандл, /ubus
# JSON-RPC (путь браузера), ACL anon-vs-admin, session.login, handler-валидация
# без деструктивных эффектов. Нужен интернет в VM (apk add uhttpd-mod-ubus).
qemu-webui-v2:
	@./tests/qemu/webui-v2.sh

# T3c — полный install. Поднимает VM, заливает репо в /opt/cheburnet,
# запускает setup/install.sh целиком на реальном busybox-OpenWrt. Ловит
# coreutils-vs-busybox несовместимости (например, отсутствие команды
# `install`), регрессии в порядке шагов, проблемы манифеста и т.п.
# Шаги 01-amneziawg и 05-wifi на x86-snapshot падают ожидаемо
# (нет kmod-amneziawg / нет Wi-Fi-чипа). Реальный полный happy-path
# тестируется на Cudy/Beryl AX вручную.
qemu-install:
	@./tests/qemu/install.sh

# T4 — hardware tests. Полный прогон на реальном Beryl AX (или совместимом):
# bootstrap, install через RPC, проверка всех сервисов и DNS, тест RPC-кнопок,
# CLI-тулинг, reboot+steady-state, фейл-инжекшен. ~25-35 мин.
# Не входит в CI — требует физический роутер и SSH-доступ. См.
# tests/hardware/README.md. ROUTER=root@<ip> — целевой роутер.
ROUTER ?= root@192.168.1.1
BRANCH ?= master
hardware:
	@./tests/hardware/run-all.sh $(ROUTER) $(BRANCH)
