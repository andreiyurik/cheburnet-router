// reset.uc — полный teardown cheburnet-конфигурации (импурно, router-side).
//
//   ucode -R reset.uc
//
// Снимает ВСЁ, что поставила установка, и возвращает роутер к до-cheburnet состоянию:
// nft/ip-правила + NAT-зона (firewall --teardown), семейный режим, наши uci-секции
// (network, dhcp, https-dns-proxy), /etc/cheburnet. Пакеты НЕ удаляем (apk del — забота
// пользователя), Wi-Fi и пароль root НЕ трогаем (рабочие настройки, не data-plane).
// Это НЕ firstboot v1: сбрасывается cheburnet, не роутер.
//
// «Что считать нашим» НЕ хардкодим: имена секций/записей приходят из шагов-владельцев
// (vpn.owned_sections / dns.owned_sections / doh.listen_prefix) —
// переименование в шаге автоматически подхватывается здесь, дрейфа нет.
//
// Идемпотентно: повторный запуск на уже чистой системе — no-op (uci -q семантика).
// Запускается обработчиком в фоне (setsid), код выхода → done-маркер. Проверяется в QEMU.

import { readfile, unlink, rmdir, lsdir } from "fs";
import { sh, run_stdin, uci_batch } from "../lib/proc.uc";
import { owned_sections } from "../steps/vpn/vpn.uc";
import { owned_sections as dns_owned_sections } from "../steps/dns/dns.uc";
import { listen_prefix } from "../steps/doh/doh.uc";
import { config_path as sb_config, service_name as sb_service } from "../steps/singbox/singbox.uc";

let SELF = sourcepath(0, true);
let ENGINE = SELF + "/..";              // engine/
const ETC_CHEBURNET = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";

// routing_opts из сохранённой конфигурации — teardown firewall использует их же (mark/table).
let raw = readfile(ETC_CHEBURNET + "/install.json");
let cfg = (raw && substr(trim(raw), 0, 1) == "{") ? json(raw) : {};
let ro = (type(cfg.routing_opts) == "object") ? cfg.routing_opts : {};

print("reset: снимаю data-plane (nft/ip/NAT-зона)\n");
run_stdin(sprintf("ucode -R %s/steps/firewall/apply.uc --teardown", ENGINE),
	sprintf("%J", { domains: [], routing_opts: ro }));

// network: секции туннеля — имена даёт vpn-шаг.
print("reset: убираю туннель из network\n");
let net = owned_sections(null);
let nops = [];
for (let i = 0; i < length(net); i++)
	push(nops, "delete network." + net[i]);
uci_batch(nops, "network");

// dhcp: наши ipset-секции (имена из dns.owned_sections), DoH-upstream'ы (префикс из doh),
// noresolv. Teardown толерантен — код batch не проверяем (отсутствие записей — норма).
print("reset: чищу dnsmasq-привязки\n");
let ops = [];
let dns_sects = dns_owned_sections(null);
for (let i = 0; i < length(dns_sects); i++)
	if (length(trim(sh(sprintf("uci -q get dhcp.%s 2>/dev/null", dns_sects[i])))) > 0)
		push(ops, sprintf("delete dhcp.%s", dns_sects[i]));
let pfx = listen_prefix();
let srv = trim(sh("uci -q get dhcp.@dnsmasq[0].server 2>/dev/null"));
let stoks = length(srv) > 0 ? split(srv, /[ \t]+/) : [];
for (let i = 0; i < length(stoks); i++)
	if (substr(stoks[i], 0, length(pfx)) == pfx)
		push(ops, sprintf("del_list dhcp.@dnsmasq[0].server='%s'", stoks[i]));
push(ops, "delete dhcp.@dnsmasq[0].noresolv");
uci_batch(ops, "dhcp");

// https-dns-proxy: стоп + снести все секции (наш шаг и так владел конфигом целиком).
print("reset: убираю https-dns-proxy\n");
sh("/etc/init.d/https-dns-proxy stop >/dev/null 2>&1");
let hdp = trim(sh("uci -q show https-dns-proxy 2>/dev/null | awk -F'[.=]' '/^https-dns-proxy\\.[^.=]+=/{print $2}' | sort -u"));
let hsects = length(hdp) > 0 ? split(hdp, /\n+/) : [];
let hops = [];
for (let i = 0; i < length(hsects); i++)
	push(hops, sprintf("delete https-dns-proxy.%s", hsects[i]));
if (length(hops) > 0)
	uci_batch(hops, "https-dns-proxy");

// sing-box (Full-тир): выключить сервис + снять uci-секцию и config.json. Только если ставился
// (Light его не трогает) — иначе не плодим стороннего /etc/config/sing-box. Идемпотентно.
if (trim(sh("[ -f /etc/config/sing-box ] && echo y || true")) == "y") {
	print("reset: убираю sing-box (Full-тир)\n");
	sh(sprintf("/etc/init.d/%s stop >/dev/null 2>&1", sb_service()));
	sh(sprintf("/etc/init.d/%s disable >/dev/null 2>&1", sb_service()));
	uci_batch([ "delete sing-box.main" ], "sing-box");
	unlink(sb_config());
}

// /etc/cheburnet: конфигурация, install-токен, кэш импортированного списка.
print("reset: удаляю /etc/cheburnet\n");
let files = lsdir(ETC_CHEBURNET) ?? [];
for (let i = 0; i < length(files); i++)
	unlink(ETC_CHEBURNET + "/" + files[i]);
rmdir(ETC_CHEBURNET);

// Перечитать конфиги: network (туннель ушёл), firewall уже reload'нут teardown'ом, dnsmasq.
sh("/etc/init.d/network reload >/dev/null 2>&1");
sh("/etc/init.d/dnsmasq restart >/dev/null 2>&1");

print("reset: готово — cheburnet-конфигурация снята, роутер вернулся к обычной маршрутизации\n");
