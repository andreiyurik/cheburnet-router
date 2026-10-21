// test_replace.uc — host-тесты пояса замены AWG-конфига (replace_vpn.uc): реальный скрипт как subprocess
// + фейки (harness.uc). Инварианты: сбой на любой фазе → авто-возврат прежнего состояния; commit только
// после свежего handshake. Различаем исходы по артефактам: commit ВЫБРАСЫВАЕТ каталог снимка, restore — оставляет.

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { writefile, readfile, access } from "fs";
import { mk_sandbox, run_uc, calls, cleanup } from "./harness.uc";

const GOOD_AWG =
	"[Interface]\n" +
	"PrivateKey = cHJpdmF0ZUtleVByaXZhdGVLZXlQcml2YXRlMTI=\n" +
	"Address = 10.8.0.2/32\n" +
	"[Peer]\n" +
	"PublicKey = cHVibGljS2V5UHVibGljS2V5UHVibGljS2V5MTI=\n" +
	"Endpoint = 192.0.2.10:51820\n" +
	"AllowedIPs = 0.0.0.0/0\n";

// === replace_vpn.uc (AWG) ===

test("replace_vpn: битый конфиг → отказ шага, restore, снимок сохранён", () => {
	let sb = mk_sandbox();
	let r = run_uc(sb, "install/replace_vpn.uc", null, "это не AWG-конфиг");
	eq(r.rc, 1, "exit 1");
	ok(index(r.out, "откат") >= 0, "об откате сказано");
	ok(access(sb.snap), "restore-путь: снимок НЕ выброшен (это делает только commit)");
	cleanup(sb);
});

test("replace_vpn: свежий handshake → commit (снимок выброшен)", () => {
	let sb = mk_sandbox();
	// Свежий = новее старта операции: ставим заведомое будущее.
	writefile(sb.fake + "/awg.out", sprintf("PUBKEY\t%d\n", time() + 3600));
	let r = run_uc(sb, "install/replace_vpn.uc", null, GOOD_AWG);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(r.out, "новый конфиг работает") >= 0, "успех подтверждён handshake'ом");
	ok(!access(sb.snap), "commit: снимок выброшен");
	let st = json(readfile(sb.etc + "/profiles.json"));
	eq(st.active, "p1", "подтверждённый сервер запомнен активным профилем «Сервер 1»");
	eq(readfile(sb.etc + "/profiles/p1.conf"), GOOD_AWG, "его .conf сохранён для переключения обратно");
	cleanup(sb);
});

// two_profiles(sb) — «Германия» (активна) и «Нидерланды» уже сохранены.
function two_profiles(sb) {
	writefile(sb.etc + "/profiles.json", sprintf("%J", { profiles: [ { id: "p1", name: "Германия" },
		{ id: "p2", name: "Нидерланды" } ], active: "p1", next_id: 3 }));
}

test("replace_vpn --profile --auto: commit отмечает профиль активным, смену — автоматической", () => {
	let sb = mk_sandbox();
	two_profiles(sb);
	writefile(sb.fake + "/awg.out", sprintf("PUBKEY\t%d\n", time() + 3600));
	let r = run_uc(sb, "install/replace_vpn.uc", "--profile p2 --auto", GOOD_AWG);
	eq(r.rc, 0, r.out);
	let st = json(readfile(sb.etc + "/profiles.json"));
	eq(st.active, "p2");
	eq(st.last_switch.from, "Германия");
	eq(st.last_switch.auto, true);
	cleanup(sb);
});

test("replace_vpn --profile: нет handshake → активный профиль НЕ меняется", () => {
	let sb = mk_sandbox();
	two_profiles(sb);
	let r = run_uc(sb, "install/replace_vpn.uc", "--profile p2", GOOD_AWG);
	eq(r.rc, 1, r.out);
	eq(json(readfile(sb.etc + "/profiles.json")).active, "p1", "откатился — значит и не подключён");
	cleanup(sb);
});

test("replace_vpn: handshake не пришёл за окно → restore, честное сообщение", () => {
	let sb = mk_sandbox();
	// СТАРЫЙ handshake (до старта) — «сервер молчит»: свежести нет, откат обязателен.
	writefile(sb.fake + "/awg.out", "PUBKEY\t1\n");
	let r = run_uc(sb, "install/replace_vpn.uc", null, GOOD_AWG);
	eq(r.rc, 1, "exit 1");
	ok(index(r.out, "возвращаю прежний конфиг") >= 0, "причина отката названа");
	ok(access(sb.snap), "restore-путь: снимок не выброшен");
	cleanup(sb);
});

exit(summary());
