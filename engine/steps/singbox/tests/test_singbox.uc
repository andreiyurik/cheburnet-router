// test_singbox.uc — юнит-тесты legacy-шага sing-box: имена артефактов, которыми он владеет. Без роутера.
//   ucode -R engine/steps/singbox/tests/test_singbox.uc
// Full-тир заморожен (ADR 0010): разбор ссылок и генерация конфига — в теге reality-final.

import { test, eq, ok, deep_eq, summary } from "../../../lib/assert.uc";
import { tun_interface, config_path, service_name, network_sections } from "../singbox.uc";

test("артефакты шага: TUN, конфиг, сервис — дефолты, которые знает живой роутер", () => {
	eq(tun_interface(), "singtun0", "тот же интерфейс, что видят firewall и invariants");
	eq(config_path(), "/etc/sing-box/config.json");
	eq(service_name(), "sing-box");
	eq(config_path({ config_path: "/tmp/x.json" }), "/tmp/x.json", "override для host-тестов");
	eq(tun_interface({ bogus: "x" }), "singtun0", "незнакомый ключ opts игнорируется");
});

// ИНВАРИАНТ: [0] — интерфейс; по нему apply.uc делает ifup/ifdown, а reset сносит ровно эти секции.
test("network_sections: интерфейс первым, затем обе half-route секции", () => {
	deep_eq(network_sections(), [ "singtun", "cheburnet_str0", "cheburnet_str1" ]);
});

exit(summary());
