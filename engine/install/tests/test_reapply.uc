// test_reapply.uc — host-тест восстановления ip-части data-plane (install/reapply.uc) на фейках.
//
// ЗАЧЕМ ЭТОТ КОД ВООБЩЕ ЕСТЬ (оплачено живым прогоном на GL-MT3000, 2026-08-01): nft-часть
// переживает перезагрузку файлом в /etc/nftables.d/, а `ip rule fwmark → table` и default-маршрут
// direct-таблицы живут только в ЯДРЕ и после ребута исчезают. Симптом худший из возможных: панель
// зелёная, туннель поднят, наборы direct наполняются — но помеченный трафик уходит В ТУННЕЛЬ,
// потому что направлять его стало нечем. Split-tunnel, главная функция продукта, молча выключается.
//
// ЧТО ПРОВЕРЯЕМ ЗДЕСЬ: РЕШЕНИЕ переприменения — какой WAN он берёт и что передаёт шагу firewall.
// Сам шаг подменяем заглушкой: полностью он в sandbox не исполним (нет /etc/init.d/firewall), а его
// содержимое проверено своими юнитами. Что правила реально возвращаются после загрузки — уровень
// QEMU (qemu-reboot-v2) и физического роутера.

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { writefile, mkdir } from "fs";
import { mk_sandbox, run_uc, cleanup, shq } from "./harness.uc";
import { sh } from "../../lib/proc.uc";

// stub_engine(sb) → путь к «движку», где шаг firewall лишь пишет полученный payload в файл.
function stub_engine(sb) {
	let dir = sb.root + "/engine";
	mkdir(dir, 0o755); mkdir(dir + "/steps", 0o755); mkdir(dir + "/steps/firewall", 0o755);
	writefile(dir + "/steps/firewall/apply.uc",
		sprintf("import { stdin, writefile } from \"fs\";\nwritefile(%s, stdin.read(\"all\") ?? \"\");\n",
			shq(sb.root + "/payload.json")));
	return dir;
}

function payload_of(sb) {
	return sh(sprintf("cat %s 2>/dev/null", shq(sb.root + "/payload.json")));
}

test("reapply: передаёт шагу домены, туннель и СВЕЖИЙ WAN из netifd", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	writefile(sb.etc + "/install.json",
		'{"protocol":"awg","routing_opts":{"wan_if":"eth0","wan_gw":"192.0.2.1","tunnel_if":"awg0"},' +
		'"domains":["example.com"]}\n');
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "exit 0: " + r.out);
	let p = payload_of(sb);
	ok(index(p, '"example.com"') >= 0, "домены взяты из сохранённой конфигурации");
	ok(index(p, '"tunnel_if"') >= 0 && index(p, "awg0") >= 0, "туннель передан (NAT-зона и метки)");
	ok(index(p, "192.0.2.1") >= 0, "шлюз WAN — для default-маршрута direct-таблицы");
	cleanup(sb);
});

test("reapply: WAN берётся ЗАНОВО, а не из install.json (сменился шлюз — правило не устареет)", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	// В файле — прежний WAN; netifd (фейк wan.json) отдаёт актуальный eth0 / 192.0.2.1.
	writefile(sb.etc + "/install.json",
		'{"protocol":"awg","routing_opts":{"wan_if":"eth9","wan_gw":"10.9.9.9","tunnel_if":"awg0"},' +
		'"domains":[]}\n');
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "exit 0: " + r.out);
	let p = payload_of(sb);
	ok(index(p, "192.0.2.1") >= 0, "шлюз взят из netifd");
	ok(index(p, "10.9.9.9") < 0, "устаревший шлюз из файла НЕ применён");
	cleanup(sb);
});

test("reapply: на ненастроенном роутере — тихий no-op (хук зовётся на каждый ifup WAN)", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "успех без конфигурации: " + r.out);
	eq(trim(r.out), "__rc=0", "ни строчки в лог — иначе log-snapshot забьётся шумом на каждом ifup");
	eq(trim(payload_of(sb)), "", "шаг не запускался");
	cleanup(sb);
});

test("reapply: протокол Full-тира → в шаг уезжает singtun0, а не awg0", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	// tunnel_if в старых установках мог не сохраниться — выводим из протокола.
	writefile(sb.etc + "/install.json",
		'{"protocol":"reality","routing_opts":{"wan_if":"eth0","wan_gw":"192.0.2.1"},"domains":[]}\n');
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "exit 0: " + r.out);
	let p = payload_of(sb);
	ok(index(p, "singtun0") >= 0, "NAT-зона и метки должны смотреть на активный туннель");
	ok(index(p, "awg0") < 0, "чужой туннель в план не попадает");
	cleanup(sb);
});

test("reapply: WAN ещё не поднят → НЕ применяем половину (правило без маршрута хуже, чем ничего)", () => {
	let sb = mk_sandbox();
	let eng = stub_engine(sb);
	writefile(sb.etc + "/install.json",
		'{"protocol":"awg","routing_opts":{"wan_if":"eth0","wan_gw":"192.0.2.1","tunnel_if":"awg0"},' +
		'"domains":["example.com"]}\n');
	// netifd молчит про wan и дефолт-маршрута в ядре тоже нет — ровно первые секунды после загрузки.
	writefile(sb.fake + "/wan.json", "");
	writefile(sb.fake + "/route_default.out", "");
	let r = run_uc(sb, "install/reapply.uc", null, null, sprintf("ENGINE_DIR=%s", shq(eng)));
	eq(r.rc, 0, "не ошибка, а «ещё не время»: " + r.out);
	eq(trim(payload_of(sb)), "", "шаг не запускался — иначе правило увело бы трафик в пустую таблицу");
	cleanup(sb);
});

exit(summary());
