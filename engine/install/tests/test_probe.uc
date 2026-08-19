// test_probe.uc — host-тест connectivity-пробы Full-тира (install/probe.uc) через фейки.
//
// Проба — гейт commit'а у run.uc и replace_singbox.uc; её инварианты:
//   • нет процесса sing-box → false БЕЗ сетевых действий (быстрый гейт);
//   • пин host-route не подтвердился → fetch НЕ запускается (иначе успешный fetch через WAN
//     соврал бы «туннель работает» — fail-safe);
//   • host-route снимается ВСЕГДА, и на успехе, и на провале (не оставляем липкий маршрут).
// tunnel_connectivity — функция, а не CLI: гоняем через одноразовую обёртку в sandbox.

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { writefile } from "fs";
import { mk_sandbox, run_uc, calls, cleanup, ENGINE } from "./harness.uc";

// probe(sb) → { rc, out } — вывод "OK:<reason>"/"NO:<reason>" от tunnel_connectivity("singtun0").
function probe(sb) {
	let wrapper = sb.root + "/probe-wrapper.uc";
	writefile(wrapper,
		sprintf('import { tunnel_connectivity } from "%s/install/probe.uc";\n', ENGINE) +
		'let r = tunnel_connectivity("singtun0");\n' +
		'print((r.ok ? "OK" : "NO") + ":" + (r.reason ?? "-"));\n');
	return run_uc(sb, wrapper);
}

test("sing-box не запущен → false/process, маршруты не трогаются", () => {
	let sb = mk_sandbox();
	// pgrep.rc по умолчанию 1 (процесса нет).
	let r = probe(sb);
	ok(index(r.out, "NO:process") >= 0, "проба честно провалена с адресной причиной");
	ok(index(calls(sb), "ip route replace") < 0, "host-route не ставился");
	cleanup(sb);
});

test("пин не лёг (маршрут на WAN) → false/route, fetch НЕ запускался, маршрут снят", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/pgrep.rc", "0");
	writefile(sb.fake + "/route_get.out", "1.1.1.1 dev eth0 src 203.0.113.7\n");
	writefile(sb.fake + "/fetch.rc", "0"); // fetch «сработал бы» — но его нельзя запускать
	let r = probe(sb);
	ok(index(r.out, "NO:route") >= 0, "WAN-обход не выдан за туннель, причина адресная");
	ok(index(calls(sb), "uclient-fetch") < 0, "fetch не запускался без пина");
	ok(index(calls(sb), "ip route del") >= 0, "host-route снят и на провале");
	cleanup(sb);
});

test("пин лёг, fetch прошёл → true, маршрут снят и на успехе", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/pgrep.rc", "0");
	writefile(sb.fake + "/route_get.out", "1.1.1.1 dev singtun0 src 10.9.0.2\n");
	writefile(sb.fake + "/fetch.rc", "0");
	let r = probe(sb);
	ok(index(r.out, "OK:-") >= 0, "проба подтверждена, reason=null");
	ok(index(calls(sb), "uclient-fetch") >= 0, "байты гонялись через fetch");
	ok(index(calls(sb), "ip route del") >= 0, "host-route снят после успеха");
	cleanup(sb);
});

test("пин лёг, но fetch упал → false/fetch (процесс жив ≠ туннель везёт)", () => {
	let sb = mk_sandbox();
	writefile(sb.fake + "/pgrep.rc", "0");
	writefile(sb.fake + "/route_get.out", "1.1.1.1 dev singtun0 src 10.9.0.2\n");
	writefile(sb.fake + "/fetch.rc", "1");
	let r = probe(sb);
	ok(index(r.out, "NO:fetch") >= 0, "живой процесс без трафика — не успех, причина адресная");
	cleanup(sb);
});

exit(summary());
