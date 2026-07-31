// reapply.uc — вернуть runtime-часть data-plane из сохранённой конфигурации (импурно, router-side).
//
//   ucode -R reapply.uc            # переприменить firewall-шаг из /etc/cheburnet/install.json
//
// ЗАЧЕМ ОТДЕЛЬНАЯ ТОЧКА ВХОДА: часть data-plane живёт только в ЯДРЕ и не переживает перезагрузку —
// правило policy-routing (`ip rule fwmark → table`) и default-маршрут этой таблицы через WAN.
// nft-часть переживает (файл /etc/nftables.d/, его грузит fw4 при старте), а ip-часть — нет.
// Итог без этого файла (поймано на живом роутере 2026-08-01): после ребута наборы direct
// наполняются, туннель поднят, панель зелёная — но помеченный трафик идёт В ТУННЕЛЬ, потому что
// правила направления нет. То есть split-tunnel, главная функция продукта, молча выключается.
// Направление безопасное (утечки нет), и именно поэтому это тихий баг, а не заметный отказ.
//
// Зовётся из двух мест: hotplug-хук на подъём WAN (загрузка роутера и переподключение канала) и
// откат поверх рабочей системы (run.uc). Одна реализация на оба случая — расхождение здесь
// означало бы «после ребута иначе, чем после отката», а такие вещи не ловятся глазами.
//
// WAN определяем ЗАНОВО, а не берём из install.json: у канала мог смениться шлюз или имя
// устройства (переподключение, смена провайдерского оборудования), и застывшая копия молча
// увела бы direct-трафик в никуда.

import { readfile } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";
import { tunnel_info, protocol_ids, default_protocol } from "./install.uc";
import { parse_wan_route } from "../preflight/parse.uc";
import { pick_wan_fallback } from "../lib/route.uc";

const ETC = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
// Путь к движку выводим от себя (как run.uc), а не хардкодим: тот же файл работает и из репозитория,
// и из /usr/share/cheburnet на роутере. ENGINE_DIR — override ТОЛЬКО для host-тестов: полный
// firewall-шаг в sandbox не исполним (в нём нет /etc/init.d/firewall), поэтому там подставляется
// шаг-заглушка, и проверяется решение переприменения — какой WAN взят и что уехало шагу.
let ENGINE = getenv("ENGINE_DIR") ?? (sourcepath(0, true) + "/..");

let raw = readfile(ETC + "/install.json");
let saved = (raw && substr(trim(raw), 0, 1) == "{") ? json(raw) : null;
// Не настроен — молча выходим: hotplug зовётся на каждый подъём WAN, в том числе на чистом роутере.
if (!saved || type(saved.routing_opts) != "object")
	exit(0);

let ro = saved.routing_opts;

// Свежий WAN: netifd — первичный источник, дефолт-маршрут мимо туннелей — фолбэк (как в run.uc).
let wr = parse_wan_route(sh("ubus call network.interface.wan status 2>/dev/null"));
if (!wr) {
	let tunnels = [];
	for (let p in protocol_ids())
		push(tunnels, tunnel_info(p).tunnel_if);
	wr = pick_wan_fallback(sh("ip -4 route show default 2>/dev/null"), tunnels);
}
// НЕ применяем, пока WAN не виден ЗДЕСЬ И СЕЙЧАС, и не подставляем сохранённые значения.
// Замер на живом роутере (2026-08-01): первый ifup после загрузки приходит на ~20-й секунде, когда
// WAN ещё не готов. Со сохранённым wan_if шаг применялся «наполовину» — правило направления
// появлялось, а маршрут в таблицу лечь не мог, и получалось состояние хуже исходного: правило
// уводит трафик в пустую таблицу. Лучше не сделать ничего: следующий ifup (WAN уже поднят)
// доведёт дело до конца.
if (!wr)
	exit(0);
ro.wan_if = wr.wan_if;
if (wr.wan_gw)
	ro.wan_gw = wr.wan_gw;

// tunnel_if мог не попасть в сохранённый конфиг (старые установки) — выводим из протокола.
if (!ro.tunnel_if)
	ro.tunnel_if = tunnel_info(saved.protocol ?? default_protocol()).tunnel_if;

let payload = sprintf("%J", {
	domains: saved.domains ?? [],
	routing_opts: ro,
	fw_opts: { tunnel_if: ro.tunnel_if },
});

let rc = run_stdin(sprintf("ucode -R %s/steps/firewall/apply.uc", ENGINE), payload);
if (rc != 0) {
	warn("cheburnet: не удалось переприменить data-plane (см. logread)\n");
	exit(1);
}
exit(0);
