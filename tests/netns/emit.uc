// emit.uc — тестовый эмиттер data-plane-артефактов для netns-harness (tests/netns/dataplane.sh).
//
//   echo '{"what":"nft","domains":["example.com"],
//          "routing_opts":{"ipv6":false,"wan_if":"wan0","mode":"home"},
//          "fw_opts":{"tunnel_if":"awg0"}}' | ucode -R tests/netns/emit.uc
//
// Печатает РОВНО тот текст, что движок применил бы на роутере — переиспользуя ПРОДАКШН-функции
// (build_firewall_plan / render_dnsmasq), а не переписывая правила в тесте. Так netns-тест проверяет
// реальный вывод генератора, а не свою копию. what ∈ nft | ip | dnsmasq | killswitch.
//
//   nft        — содержимое /etc/nftables.d/10-cheburnet.nft (сеты + mark/kill-switch цепочки);
//                тест оборачивает его в `table inet fw4 { … }` и грузит через nft -f.
//   ip         — команды policy-routing (ip rule fwmark + default в table через WAN).
//   dnsmasq    — nftset-строки dnsmasq (/<домен>/4#inet#fw4#direct) — их скармливаем реальному dnsmasq.
//   killswitch — только правила kill-switch (для отдельной проверки security-семантики).

import { stdin } from "fs";
import { build_plan, render_dnsmasq } from "../../engine/routing/routing.uc";
import { build_firewall_plan } from "../../engine/steps/firewall/firewall.uc";

let req = json(trim(stdin.read("all") ?? ""));
let rp = build_plan(req.domains ?? [], req.routing_opts);
let fw = build_firewall_plan(rp, req.fw_opts);
let what = req.what ?? "nft";

function lines(arr) {
	for (let i = 0; i < length(arr); i++)
		print(arr[i] + "\n");
}

if (what == "nft")
	print(fw.nft_file); // уже с завершающим \n
else if (what == "ip")
	lines(fw.ip_setup);
else if (what == "dnsmasq")
	lines(render_dnsmasq(rp));
else if (what == "killswitch")
	lines(fw.killswitch);
else
	die(sprintf("unknown 'what': %s", what));
