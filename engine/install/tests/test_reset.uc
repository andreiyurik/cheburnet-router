// test_reset.uc — host-тест полного teardown'а (install/reset.uc) через фейки (harness.uc).
//
// Инварианты: reset снимает data-plane (firewall teardown), наши uci-секции (имена — из
// шагов-владельцев, не хардкод) и /etc/cheburnet ЦЕЛИКОМ; идемпотентен (повтор на чистой
// системе — no-op без ошибок). Пакеты/Wi-Fi/пароль root не трогаются (проверяем от противного:
// в calls-логе нет apk/wifi/passwd). Живой fw4/netifd — QEMU; здесь — состав действий.

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { writefile, readfile, access } from "fs";
import { mk_sandbox, run_uc, calls, cleanup } from "./harness.uc";

function seed_installed(sb) {
	writefile(sb.etc + "/install.json",
		'{"routing_opts":{"wan_if":"eth0","tunnel_if":"awg0"},"domains":["example.com"]}\n');
	writefile(sb.etc + "/install-token", "TOK\n");
	writefile(sb.etc + "/direct-list", "example.com\n");
}

test("reset: /etc/cheburnet снят целиком, data-plane и туннели вычищены", () => {
	let sb = mk_sandbox();
	seed_installed(sb);
	let r = run_uc(sb, "install/reset.uc");
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(!access(sb.etc), "каталог конфигурации удалён (включая токен и кэш списка)");
	let log = calls(sb);
	ok(index(log, "nft") >= 0, "firewall teardown дошёл до nft");
	ok(index(log, "delete network.awg0") >= 0, "секции AWG-туннеля сняты");
	ok(index(log, "delete network.singtun") >= 0, "секции reality-туннеля сняты (независимо от протокола)");
	ok(index(log, "delete dhcp.@dnsmasq[0].noresolv") >= 0, "dnsmasq возвращён к обычному резолву");
	cleanup(sb);
});

test("reset НЕ трогает пакеты, Wi-Fi и пароль root", () => {
	let sb = mk_sandbox();
	seed_installed(sb);
	run_uc(sb, "install/reset.uc");
	let log = calls(sb);
	ok(index(log, "apk") < 0, "пакеты не удаляются (забота пользователя)");
	ok(index(log, "wifi") < 0, "Wi-Fi не трогается (рабочая настройка)");
	ok(index(log, "passwd") < 0, "пароль root не трогается");
	cleanup(sb);
});

test("reset идемпотентен: повтор на уже чистой системе — no-op без ошибок", () => {
	let sb = mk_sandbox();
	seed_installed(sb);
	ok(run_uc(sb, "install/reset.uc").rc == 0, "первый прогон");
	let r = run_uc(sb, "install/reset.uc");
	eq(r.rc, 0, "повтор не падает (uci -q семантика, отсутствие файлов — норма)");
	cleanup(sb);
});

exit(summary());
