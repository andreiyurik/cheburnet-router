# cheburnet-router — test targets
#
# Уровни тестов:
#   make lint        — T1: статика (shellcheck + sh -n + JSON + SHA-sync).
#   make test        — T2: unit + mock-integration на bats (host-only, ~10с).
#   make qemu        — T3a: hermetic VM smoke в qemu/KVM (~90с, без интернета).
#   make qemu-http   — T3b: VM smoke с HTTP/ubus + UI-кнопками (~3мин, нужен
#                     интернет в VM для apk add uhttpd-mod-ubus).

.PHONY: lint test test-unit test-integration qemu qemu-http

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

# T3a — hermetic. Поднимает свежий OpenWrt snapshot в qemu/KVM, кладёт наш
# rpcd-handler через ssh+cat (без apk, без интернета), проверяет что ubus
# отвечает корректным JSON. Ловит регрессии типа gawk-vs-busybox-awk и
# busybox-ash несовместимостей, которые mock-уровень T2 не видит.
qemu:
	@./tests/qemu/smoke.sh

# T3b — расширенный. Дополнительно ставит uhttpd-mod-ubus (apk update/add —
# нужен интернет!) и тестирует то, что РЕАЛЬНО делают кнопки в UI: HTTP-POST
# на /ubus с JSON-RPC, ACL anon-vs-authed, handler-валидация без destructive
# побочных эффектов (factory_reset с неправильным confirm, mode_switch
# c invalid mode и т.п.).
qemu-http:
	@./tests/qemu/smoke-http.sh
