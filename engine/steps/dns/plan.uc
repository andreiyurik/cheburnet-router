// plan.uc — CLI чистого DNS-шага: facts → uci-операции (НЕ применяет, только печатает план).
//
//   echo '{"domains":["example.com"],"routing_opts":{"ipv6":false},
//          "current":{"sections":{},"options":{}}}' | ucode -R plan.uc
//
// Принимает со stdin JSON: domains + routing_opts (для routing.build_plan), current (снимок
// uci из apply), dns_opts. Печатает строки для `uci batch`. Локально тестируется без роутера —
// current подаём вручную. Реальное чтение uci и запуск — apply.uc.

import { stdin } from "fs";
import { build_plan } from "../../routing/routing.uc";
import { build_dns_plan } from "./dns.uc";

let raw = trim(stdin.read("all") ?? "");
if (substr(raw, 0, 1) != "{")
	die("dns/plan: ожидаю JSON со stdin");

let req = json(raw);
let routing_plan = build_plan(req.domains ?? [], req.routing_opts);
let plan = build_dns_plan(routing_plan, req.current, req.dns_opts);

for (let i = 0; i < length(plan.ops); i++)
	print(plan.ops[i] + "\n");

// changed=false → пустой вывод (no-op). Сообщаем кодом: 0 = есть изменения или нечего делать,
// здесь exit всегда 0; машинно состояние видно по наличию строк. Для --json — полный план.
if (length(ARGV) > 0 && ARGV[0] == "--json")
	print(sprintf("%J\n", plan));
