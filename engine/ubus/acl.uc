// acl.uc — CLI: печатает rpcd-acl.json, выведенный из REGISTRY в ubus.uc.
//
//   ucode -R acl.uc > engine/ubus/rpcd-acl.json
//
// tests/test_ubus.uc сверяет коммитнутый файл с выводом отсюда. Меняешь реестр — перегенери.

import { build_acl } from "./ubus.uc";

print(sprintf("%.4J\n", build_acl()));
