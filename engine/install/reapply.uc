// reapply.uc — вернуть runtime-часть data-plane из сохранённой конфигурации (импурно, router-side).
//
//   ucode -R reapply.uc            # переприменить firewall-шаг из /etc/cheburnet/install.json
//
// Зовётся из двух мест: hotplug-хук на подъём WAN и откат поверх рабочей системы (run.uc) —
// одна реализация на оба случая, чтобы «после ребута» не расходилось с «после отката».

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

// ИНВАРИАНТ: ip-часть policy-routing (`ip rule fwmark → table` + default таблицы через WAN)
// живёт только в ЯДРЕ и не переживает перезагрузку (nft-часть переживает файлом в
// /etc/nftables.d/). Без переприменения direct-трафик молча уходит В ТУННЕЛЬ — безопасно, но
// split-tunnel тихо выключается; hotplug-хук поэтому ждёт оба артефакта, nft-правило и route
// (см. steps/firewall/firewall.uc render_hotplug).
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
// Шрам: первый ifup после загрузки (~20с) может опережать готовность WAN. Применить с
// сохранённым wan_if тогда — хуже, чем ничего: правило появится, а маршрут в таблицу не ляжет
// (направляет в пустоту). Поэтому без свежего WAN не применяем вовсе — следующий ifup доведёт.
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
