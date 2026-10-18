// test_profiles.uc — юнит-тесты профилей AWG-серверов и решения автосмены. Без роутера.
//   ucode -R engine/profiles/tests/test_profiles.uc

import { test, eq, ok, deep_eq, summary } from "../../lib/assert.uc";
import { normalize, add, rename, remove, reorder, mark_active, failover_order, decide_failover,
         public_view, MAX_PROFILES, FAILOVER_AFTER, FAILOVER_RETRY } from "../profiles.uc";

// three() — «Германия» (активна), «Нидерланды», «Финляндия» в этом приоритете.
function three() {
	let st = normalize(null);
	for (let n in [ "Германия", "Нидерланды", "Финляндия" ]) st = add(st, n).state;
	return mark_active(st, "p1", 1000, false);
}

test("normalize: мусор → пустой дефолт; чужой id и висячий active отброшены", () => {
	let st = normalize({ profiles: [ { id: "../etc/passwd", name: "x" }, { id: "p2", name: "ok" } ], active: "p9" });
	deep_eq(map(st.profiles, (p) => p.id), [ "p2" ]);
	eq(st.active, null);
	eq(st.auto, false, "автосмена по умолчанию выключена — включает человек");
	eq(normalize("мусор").next_id, 1);
});

test("add: id из счётчика, имя чистится, дубли и пустое — отказ", () => {
	let st = add(normalize(null), "  Германия\n").state;
	eq(st.profiles[0].id, "p1");
	eq(st.profiles[0].name, "Германия", "управляющие символы и пробелы по краям убраны");
	let en = add(normalize(null), "Germany").state;
	ok(!add(en, "germany").ok, "регистр не делает имя другим (ASCII — квирк lc() в ucode)");
	ok(!add(st, "   ").ok);
	ok(add(st, "Нидерланды-Амстердам-резервный").ok, "30 кириллических букв влезают");
	ok(!add(st, "Нидерланды-Амстердам-резервный-2-ой").ok, "больше 32 букв — отказ");
	let st2 = remove(add(st, "Нидерланды").state, "p2").state;
	eq(add(st2, "Финляндия").id, "p3", "id после удаления не переиспользуется (старый .conf не всплывёт)");
});

test("add: не больше MAX_PROFILES", () => {
	let st = normalize(null);
	for (let i = 0; i < MAX_PROFILES; i++) st = add(st, sprintf("S%d", i)).state;
	let r = add(st, "лишний");
	ok(!r.ok);
	ok(index(r.error, "16") >= 0);
});

test("rename / remove: активный удалить нельзя, остальные — можно", () => {
	let st = three();
	ok(!remove(st, "p1").ok, "на активном держится весь дом");
	eq(length(remove(st, "p2").state.profiles), 2);
	eq(rename(st, "p2", "Амстердам").state.profiles[1].name, "Амстердам");
	ok(!rename(st, "p2", "Германия").ok, "имя занято");
	ok(rename(st, "p1", "Германия (Франкфурт)").ok, "своё имя можно менять");
});

test("reorder: только перестановка текущих id", () => {
	let st = three();
	deep_eq(map(reorder(st, [ "p3", "p1", "p2" ]).state.profiles, (p) => p.id), [ "p3", "p1", "p2" ]);
	ok(!reorder(st, [ "p1", "p2" ]).ok, "не все");
	ok(!reorder(st, [ "p1", "p1", "p2" ]).ok, "повтор");
	ok(!reorder(st, [ "p1", "p2", "p9" ]).ok, "чужой id");
});

test("mark_active: запоминает смену для панели", () => {
	let st = mark_active(three(), "p2", 2000, true);
	eq(st.active, "p2");
	deep_eq(st.last_switch, { from: "Германия", to: "Нидерланды", at: 2000, auto: true });
	deep_eq(mark_active(st, "p2", 3000, false).last_switch.at, 2000, "повторная отметка того же — не смена");
});

test("failover_order: ниже активного, затем по кругу; активный не включён", () => {
	let st = three();
	deep_eq(failover_order(st), [ "p2", "p3" ]);
	deep_eq(failover_order(mark_active(st, "p2", 0, false)), [ "p3", "p1" ]);
	st.active = null;
	deep_eq(failover_order(st), [ "p1", "p2", "p3" ]);
});

// run(n, ctx) — прогнать n тиков с одинаковым контекстом, вернуть последний результат.
function run(n, ctx, prev) {
	let r = { state: prev ?? {} };
	for (let i = 0; i < n; i++) r = decide_failover(ctx, r.state);
	return r;
}

test("decide_failover: ждёт FAILOVER_AFTER мёртвых тиков, потом пробует следующий по приоритету", () => {
	let ctx = { st: three(), eligible: true, tunnel_alive: false, wan_online: true };
	eq(run(FAILOVER_AFTER - 1, ctx).action, null, "одна-две неудачи — переходное состояние");
	let r = run(FAILOVER_AFTER, ctx);
	deep_eq(r.action, { profile: "p2" });
	ok(index(r.log[0], "«Германия» не отвечает") == 0);
	deep_eq(decide_failover(ctx, r.state).action, { profile: "p3" }, "p2 не помог — следующий");
});

test("decide_failover: нет домашнего интернета — не перебирает, пишет об этом один раз", () => {
	let ctx = { st: three(), eligible: true, tunnel_alive: false, wan_online: false };
	let r = run(FAILOVER_AFTER, ctx);
	eq(r.action, null);
	eq(length(r.log), 1);
	eq(length(decide_failover(ctx, r.state).log), 0, "не спамит журнал каждые 5 минут");
});

test("decide_failover: все перебраны — тишина, повтор круга через FAILOVER_RETRY", () => {
	let ctx = { st: three(), eligible: true, tunnel_alive: false, wan_online: true };
	let r = run(FAILOVER_AFTER + 2, ctx);   // p2, p3 испробованы, кандидатов нет
	eq(r.action, null);
	ok(index(r.log[0], "ни один") == 0);
	let quiet = run(FAILOVER_RETRY - 1, ctx, r.state);
	eq(quiet.action, null);
	deep_eq(decide_failover(ctx, quiet.state).action, { profile: "p2" }, "через час — новый круг");
});

test("decide_failover: короткий провал WAN не сбрасывает часовую паузу после полного круга", () => {
	let ctx = { st: three(), eligible: true, tunnel_alive: false, wan_online: true };
	let r = run(FAILOVER_AFTER + 2, ctx);          // круг пройден, exhausted
	r = decide_failover({ ...ctx, wan_online: false }, r.state);
	r = decide_failover(ctx, r.state);
	eq(r.action, null);
	eq(length(r.log), 0, "не повторяет «ни один не ответил» и не начинает час заново");
});

test("decide_failover: туннель ожил — сброс; не eligible или один профиль — ничего", () => {
	let dead = { st: three(), eligible: true, tunnel_alive: false, wan_online: true };
	let r = run(FAILOVER_AFTER, dead);
	let back = decide_failover({ ...dead, tunnel_alive: true }, r.state);
	deep_eq(back.state, {});
	deep_eq(back.log, [ "VPN снова работает" ]);
	eq(run(10, { ...dead, eligible: false }).action, null);
	let one = normalize(null); one = add(one, "Один").state;
	eq(run(10, { ...dead, st: one }).action, null, "переключаться не на что");
});

test("public_view: без секретов; активный виден только при AWG", () => {
	let v = public_view(three(), "awg");
	eq(v.active, "p1");
	ok(v.profiles[0].active);
	eq(v.max, MAX_PROFILES);
	let r = public_view(three(), "reality");
	eq(r.active, null, "на Reality ни один AWG-профиль не подключён");
	ok(!r.profiles[0].active);
});

summary();
