// test_replace.uc — host-тесты поясов замены туннель-конфига: replace_vpn.uc (AWG) и
// replace_singbox.uc (оба Full-протокола). Реальные скрипты как subprocess + фейки (harness.uc).
//
// Ключевые инварианты (оплачены инцидентами v1):
//   • сбой на ЛЮБОЙ фазе (apply / health) → авто-возврат прежнего состояния, пользователь
//     не остаётся без туннеля;
//   • commit только после ПОДТВЕРЖДЁННОГО здоровья (свежий handshake / connectivity-probe);
//   • у reality config.json — внешний файл вне uci-снимка: его бэкап/возврат — руками,
//     включая тонкий случай «чистой системы» (конфига не было → новый НЕ оставляем).
// Различаем исходы по артефактам: commit ВЫБРАСЫВАЕТ каталог снимка, restore — оставляет.

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

const GOOD_VLESS =
	"vless://8be3c9c5-33b8-4bd5-91cb-1cdef34a8783@203.0.113.5:443" +
	"?security=reality&pbk=PBK_TEST_KEY&sni=example.com&sid=ab12&flow=xtls-rprx-vision#test";

const GOOD_HY2 =
	"hysteria2://HY2_TEST_PASSWORD@203.0.113.5:8443,9000-9100" +
	"?sni=example.com&obfs=salamander&obfs-password=OBFS_TEST_KEY#test";

// Проба reality живёт: sing-box «запущен», host-route лёг на туннель, fetch через него прошёл.
function probe_alive(sb) {
	writefile(sb.fake + "/pgrep.rc", "0");
	writefile(sb.fake + "/route_get.out", "1.1.1.1 dev singtun0 src 10.9.0.2\n");
	writefile(sb.fake + "/fetch.rc", "0");
}

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

// === replace_singbox.uc (Full-тир: VLESS+Reality) ===

test("replace_singbox: битый вход → отказ шага, старый config.json цел, .bak поглощён", () => {
	let sb = mk_sandbox();
	writefile(sb.sbconf, "СТАРЫЙ РАБОЧИЙ КОНФИГ\n");
	let r = run_uc(sb, "install/replace_singbox.uc", null, "мусор — не vless и не JSON");
	eq(r.rc, 1, "exit 1");
	eq(readfile(sb.sbconf), "СТАРЫЙ РАБОЧИЙ КОНФИГ\n", "config.json возвращён");
	ok(!access(sb.sbconf + ".bak"), ".bak поглощён восстановлением");
	cleanup(sb);
});

test("replace_singbox: проба прошла → commit, новый config.json на месте", () => {
	let sb = mk_sandbox();
	writefile(sb.sbconf, "СТАРЫЙ РАБОЧИЙ КОНФИГ\n");
	probe_alive(sb);
	let r = run_uc(sb, "install/replace_singbox.uc", null, GOOD_VLESS);
	eq(r.rc, 0, "exit 0: " + r.out);
	ok(index(r.out, "новый конфиг работает") >= 0, "успех подтверждён пробой");
	let cfg = readfile(sb.sbconf) ?? "";
	ok(index(cfg, "PBK_TEST_KEY") >= 0, "config.json — из НОВОЙ ссылки");
	ok(index(cfg, "СТАРЫЙ") < 0, "старый конфиг замещён");
	ok(!access(sb.sbconf + ".bak"), ".bak зачищен на commit");
	ok(!access(sb.snap), "commit: снимок выброшен");
	cleanup(sb);
});

test("replace_singbox: туннель не отозвался → старый config.json возвращён байт-в-байт", () => {
	let sb = mk_sandbox();
	writefile(sb.sbconf, "СТАРЫЙ РАБОЧИЙ КОНФИГ\n");
	probe_alive(sb);
	writefile(sb.fake + "/fetch.rc", "1"); // трафик через туннель не пошёл
	let r = run_uc(sb, "install/replace_singbox.uc", null, GOOD_VLESS);
	eq(r.rc, 1, "exit 1");
	ok(index(r.out, "возвращаю прежний конфиг") >= 0, "причина отката названа");
	eq(readfile(sb.sbconf), "СТАРЫЙ РАБОЧИЙ КОНФИГ\n", "старый config.json возвращён");
	ok(!access(sb.sbconf + ".bak"), ".bak поглощён");
	cleanup(sb);
});

test("replace_singbox на чистой системе: провал пробы НЕ оставляет новый config.json", () => {
	let sb = mk_sandbox();
	// Конфига не было вовсе (свежая система): restore обязан УБРАТЬ новый, а не «вернуть пустоту».
	probe_alive(sb);
	writefile(sb.fake + "/fetch.rc", "1");
	let r = run_uc(sb, "install/replace_singbox.uc", null, GOOD_VLESS);
	eq(r.rc, 1, "exit 1");
	ok(!access(sb.sbconf), "новый config.json убран — системы «полу-Full» не остаётся");
	cleanup(sb);
});

// Hysteria2 заморожена (ADR 0009): ссылка отвергается ДО подмены живого конфига, с выходом в тексте.
test("replace_singbox: hy2-ссылка → отказ «больше не поддерживается», рабочий конфиг не тронут", () => {
	let sb = mk_sandbox();
	writefile(sb.sbconf, "СТАРЫЙ РАБОЧИЙ КОНФИГ\n");
	probe_alive(sb);
	let r = run_uc(sb, "install/replace_singbox.uc", null, GOOD_HY2);
	eq(r.rc, 1, "exit 1");
	eq(readfile(sb.sbconf), "СТАРЫЙ РАБОЧИЙ КОНФИГ\n", "рабочий конфиг не пострадал");
	ok(index(r.out, "больше не поддерживается") >= 0, "причина названа: " + r.out);
	cleanup(sb);
});

test("replace_singbox: проба не подтвердила маршрут через туннель → откат (fail-safe)", () => {
	let sb = mk_sandbox();
	writefile(sb.sbconf, "СТАРЫЙ\n");
	probe_alive(sb);
	// Пин не лёг: маршрут остался на WAN — успешный fetch через WAN не должен считаться успехом.
	writefile(sb.fake + "/route_get.out", "1.1.1.1 dev eth0 src 203.0.113.7\n");
	let r = run_uc(sb, "install/replace_singbox.uc", null, GOOD_VLESS);
	eq(r.rc, 1, "exit 1 — WAN-обход не выдан за живой туннель");
	eq(readfile(sb.sbconf), "СТАРЫЙ\n", "конфиг возвращён");
	cleanup(sb);
});

// РЕГРЕССИЯ живого прогона на GL-MT3000 (2026-08-01): в main-таблице не осталось маршрута по
// умолчанию (его вытеснил awg0, а его снятие ничего не вернуло) — sing-box отказался соединяться
// с сервером «no route to internet», и это выглядело как «сервер мёртв» при исправном сервере.
// Требование: шаг отказывает СРАЗУ и внятно, прежний рабочий конфиг остаётся на месте.
test("replace_singbox: без WAN-дефолта в main — отказ с причиной, прежний конфиг не тронут", () => {
	let sb = mk_sandbox();
	writefile(sb.sbconf, "СТАРЫЙ РАБОЧИЙ КОНФИГ\n");
	probe_alive(sb);
	writefile(sb.fake + "/route_default.out", "");   // main без дефолта, ifup его не вернул
	let r = run_uc(sb, "install/replace_singbox.uc", null, GOOD_VLESS);
	ok(r.rc != 0, "провал, а не молчаливый успех: " + r.out);
	ok(index(r.out, "маршрута по умолчанию") >= 0, "причина названа человеческим языком");
	eq(readfile(sb.sbconf), "СТАРЫЙ РАБОЧИЙ КОНФИГ\n", "рабочий конфиг остался прежним");
	cleanup(sb);
});

exit(summary());
