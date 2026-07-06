// acl.uc — CLI: печатает rpcd-acl.json, выведенный из реестра методов (ubus.uc).
//
//   ucode -R acl.uc > engine/ubus/rpcd-acl.json
//
// Источник правды прав — REGISTRY в ubus.uc. Этот CLI лишь сериализует build_acl() в JSON;
// тест (tests/test_ubus.uc) сверяет коммитнутый файл с выводом отсюда, чтобы права не
// разъезжались с кодом. Меняешь реестр → перегенери файл этой командой.

import { build_acl } from "./ubus.uc";

print(sprintf("%.4J\n", build_acl()));
