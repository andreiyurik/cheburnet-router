// install.uc — оркестрация установки: ЧИСТАЯ политика связывания кирпичей.
//
// Поток (см. reliability): preflight → snapshot UCI → шаги по порядку → health-check →
// commit / rollback. Здесь — чистая логика: реестр шагов и порядок, область snapshot (какие
// uci-конфиги защищаем) и решение commit/rollback/abort по результатам. Само выполнение
// (preflight, snapshot, apply шагов, health) — в run.uc (импурно, QEMU).
//
// Честность отката: ЧИСТЫЕ шаги (uci) откатываются snapshot'ом; ГРЯЗНЫЙ шаг (firewall —
// runtime nft/ip, не uci) при сбое чистится своим teardown (safe-fail), а не иллюзией uci-отката.

import { is_clean_config } from "../rollback/rollback.uc";

// Реестр шагов в порядке применения. configs — uci-конфиги, которые шаг меняет (для snapshot).
// rollback: clean = откатывается uci-snapshot'ом; dirty = состояние ядра, safe-fail через teardown.
// needs — что шагу подать на stdin (для run.uc): awg_conf | domains | none.
const STEPS = [
	{ name: "vpn",      configs: [ "network" ],                  rollback: "clean", needs: "awg_conf" },
	{ name: "dns",      configs: [ "dhcp" ],                     rollback: "clean", needs: "domains" },
	{ name: "doh",      configs: [ "https-dns-proxy", "dhcp" ],  rollback: "clean", needs: "none" },
	{ name: "adblock",  configs: [ "dhcp" ],                     rollback: "clean", needs: "none" },
	// firewall — последним: пометка/ip rule/kill-switch поверх поднятого awg0. Runtime nft/ip → dirty.
	{ name: "firewall", configs: [],                             rollback: "dirty", needs: "domains" },
];

function copy_step(s) {
	let c = [];
	for (let i = 0; i < length(s.configs); i++) push(c, s.configs[i]);
	return { name: s.name, configs: c, rollback: s.rollback, needs: s.needs };
}

// all_steps() → копия реестра (в порядке применения).
export function all_steps() {
	let out = [];
	for (let i = 0; i < length(STEPS); i++) push(out, copy_step(STEPS[i]));
	return out;
}

// enabled_steps(opts) → шаги к применению. opts.disable — список имён, которые пропустить.
export function enabled_steps(opts) {
	let disable = (opts && opts.disable) ? opts.disable : [];
	let out = [];
	for (let i = 0; i < length(STEPS); i++)
		if (index(disable, STEPS[i].name) < 0)
			push(out, copy_step(STEPS[i]));
	return out;
}

// snapshot_scope(steps) → uci-конфиги для snapshot: объединение configs ЧИСТЫХ шагов,
// только реально откатываемые (is_clean_config), без дублей, в порядке встречи. Грязные шаги
// в snapshot не входят — их безопасный откат это их собственный teardown.
export function snapshot_scope(steps) {
	let seen = {}, out = [];
	for (let i = 0; i < length(steps); i++) {
		let s = steps[i];
		if (s.rollback != "clean") continue;
		for (let j = 0; j < length(s.configs); j++) {
			let c = s.configs[j];
			if (is_clean_config(c) && !seen[c]) { seen[c] = true; push(out, c); }
		}
	}
	return out;
}

// dirty_steps(steps) → имена грязных шагов (их откат при сбое — teardown, не uci-restore).
export function dirty_steps(steps) {
	let out = [];
	for (let i = 0; i < length(steps); i++)
		if (steps[i].rollback == "dirty") push(out, steps[i].name);
	return out;
}

// decide_outcome(results) → { action, reason, failed }. action ∈ abort | rollback | commit.
//   results = { preflight:{ok}, steps:[{name,ok}...], health:{ok}|null }
// Порядок проверок = fail-safe: нет preflight → abort (ничего не трогали); упал шаг или
// health → rollback; всё ок → commit.
export function decide_outcome(results) {
	if (!results || !results.preflight || results.preflight.ok !== true)
		return { action: "abort", reason: "preflight не пройден — изменений нет", failed: [] };

	let failed = [];
	let steps = results.steps ?? [];
	for (let i = 0; i < length(steps); i++)
		if (steps[i].ok !== true) push(failed, steps[i].name);
	if (length(failed) > 0)
		return { action: "rollback", reason: sprintf("шаги упали: %s", join(", ", failed)), failed: failed };

	if (results.health && results.health.ok !== true)
		return { action: "rollback", reason: "health-check не пройден", failed: [] };

	return { action: "commit", reason: "все фазы успешны", failed: [] };
}
