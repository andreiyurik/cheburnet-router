// test_snapshot.uc — host-тест snapshot.uc (save/restore/commit) в sandbox.
//
// Фундамент каждого rollback-пояса (run.uc, replace_vpn, replace_reality): если снимок
// не возвращает конфиги байт-в-байт — «авто-откат» лишь видимость. Раньше проверялось
// только в QEMU; здесь — реальный прогон snapshot.uc как subprocess с env-override'ами
// UCI_CONFIG_DIR/SNAPSHOT_DIR (reload-команды /etc/init.d на хосте отсутствуют — no-op).

import { test, eq, ok, summary } from "../../lib/assert.uc";
import { sh } from "../../lib/proc.uc";
import { writefile, readfile, access, mkdir } from "fs";
import { protected_configs } from "../rollback.uc";

const SNAPSHOT = sourcepath(0, true) + "/../snapshot.uc";

const SB = trim(sh("mktemp -d"));
if (length(SB) == 0 || substr(SB, 0, 1) != "/")
	die("mktemp -d не дал sandbox");
const CFG  = SB + "/config";
const SNAP = SB + "/snap";

function snap_cmd(action) {
	return sprintf("UCI_CONFIG_DIR=%s SNAPSHOT_DIR=%s ucode -R %s %s 2>&1; echo __rc=$?",
		CFG, SNAP, SNAPSHOT, action);
}
function run_snap(action) {
	let out = sh(snap_cmd(action));
	let m = match(out, /__rc=([0-9]+)\s*$/);
	return { rc: m ? int(m[1]) : -1, out: out };
}
function reset_sb() {
	sh(sprintf("rm -rf %s %s && mkdir -p %s", CFG, SNAP, CFG));
}

test("save: сохраняет только существующие защищаемые конфиги, чужие не трогает", () => {
	reset_sb();
	writefile(CFG + "/network", "config interface 'lan'\n");
	writefile(CFG + "/dhcp", "config dnsmasq\n");
	writefile(CFG + "/uhttpd", "config uhttpd 'main'\n"); // не в protected_configs
	let r = run_snap("save");
	eq(r.rc, 0, "save rc=0");
	ok(access(SNAP + "/network"), "network в снимке");
	ok(access(SNAP + "/dhcp"), "dhcp в снимке");
	ok(!access(SNAP + "/uhttpd"), "чужой конфиг НЕ в снимке");
	ok(!access(SNAP + "/firewall"), "отсутствующий на системе конфиг не выдуман");
});

test("restore: возвращает конфиги байт-в-байт после порчи", () => {
	reset_sb();
	let orig = "config interface 'wan'\n\toption proto 'dhcp'\n";
	writefile(CFG + "/network", orig);
	ok(run_snap("save").rc == 0, "save");
	writefile(CFG + "/network", "ИСПОРЧЕНО УСТАНОВКОЙ\n");
	let r = run_snap("restore");
	eq(r.rc, 0, "restore rc=0");
	eq(readfile(CFG + "/network"), orig, "содержимое вернулось байт-в-байт");
});

test("restore: конфиг, которого не было в снимке, не затирается", () => {
	reset_sb();
	writefile(CFG + "/network", "net\n");
	ok(run_snap("save").rc == 0, "save (wireless не существовал)");
	writefile(CFG + "/wireless", "появился ПОСЛЕ снимка\n");
	ok(run_snap("restore").rc == 0, "restore");
	eq(readfile(CFG + "/wireless"), "появился ПОСЛЕ снимка\n",
		"restore не трогает то, чего не сохранял");
});

test("commit: снимок выброшен целиком (каталог удалён)", () => {
	reset_sb();
	writefile(CFG + "/network", "net\n");
	writefile(CFG + "/firewall", "fw\n");
	ok(run_snap("save").rc == 0, "save");
	let r = run_snap("commit");
	eq(r.rc, 0, "commit rc=0");
	ok(!access(SNAP), "каталог снимка удалён");
});

test("restore после commit: пустой снимок не портит систему (no-op)", () => {
	reset_sb();
	writefile(CFG + "/network", "живой конфиг\n");
	ok(run_snap("save").rc == 0, "save");
	ok(run_snap("commit").rc == 0, "commit");
	let r = run_snap("restore");
	eq(r.rc, 0, "restore без снимка не падает");
	eq(readfile(CFG + "/network"), "живой конфиг\n", "конфиг не тронут");
});

test("roundtrip всей области защиты: каждый конфиг из protected_configs восстановим", () => {
	reset_sb();
	let cfgs = protected_configs();
	for (let i = 0; i < length(cfgs); i++)
		writefile(CFG + "/" + cfgs[i], "оригинал " + cfgs[i] + "\n");
	ok(run_snap("save").rc == 0, "save");
	for (let i = 0; i < length(cfgs); i++)
		writefile(CFG + "/" + cfgs[i], "мусор\n");
	ok(run_snap("restore").rc == 0, "restore");
	for (let i = 0; i < length(cfgs); i++)
		eq(readfile(CFG + "/" + cfgs[i]), "оригинал " + cfgs[i] + "\n", cfgs[i]);
});

test("без действия → отказ с подсказкой (не молчаливый no-op)", () => {
	reset_sb();
	let r = run_snap("");
	ok(r.rc != 0, "нет save|restore|commit → rc!=0");
	ok(index(r.out, "save|restore|commit") >= 0, "usage в сообщении");
});

let rc = summary();
sh(sprintf("rm -rf %s", SB));
exit(rc);
