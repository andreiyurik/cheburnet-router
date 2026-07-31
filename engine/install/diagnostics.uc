// diagnostics.uc — сборка диагностического пакета для поддержки (ИМПУРНАЯ часть).
//
//   ucode -R engine/install/diagnostics.uc            # человеку в терминал
//   ucode -R engine/install/diagnostics.uc --json     # для ubus/UI: { text, removed }
//
// ЗАЧЕМ. Когда у человека «не работает», единственный способ помочь удалённо — увидеть, что
// происходит на роутере. По SSH целевой пользователь не пойдёт, поэтому пакет собирает роутер, а
// человек скачивает файл и отправляет его сам.
//
// ВЫРЕЗАНИЕ СЕКРЕТОВ — не опция: пакет уходит в мессенджер, и без чистки вместе с логами уехали
// бы рабочие ключи VPN и пароль Wi-Fi. Чистка — чистая redact() под юнит-тестами; здесь только
// сбор. Секреты никогда не покидают этот файл в исходном виде: redact применяется к ВСЕМУ тексту
// один раз перед выводом, а не к отдельным секциям (пропустить секцию тогда невозможно).
//
// Отправку в интернет роутер НЕ делает намеренно: токен бота в прошивке вытащит любой желающий,
// а в момент поломки исходящий доступ как раз может не работать. Файл + руки пользователя надёжнее.

import { readfile } from "fs";
import { sh } from "../lib/proc.uc";
import { redact } from "../lib/redact.uc";
import { tunnel_info } from "./install.uc";

const STATE_DIR     = getenv("STATE_DIR")     ?? "/tmp/cheburnet";
const ETC_CHEBURNET = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
const LOG_FILE      = STATE_DIR + "/install.log";
const CFG_FILE      = ETC_CHEBURNET + "/install.json";

// Границы объёма: пакет читает человек в чате, а не машина. Хвост важнее начала — ошибка почти
// всегда в конце.
const INSTALL_LOG_TAIL_BYTES = 8000;
const SYSLOG_TAIL_LINES      = 120;

function has_flag(name) {
	for (let i = 0; i < length(ARGV); i++)
		if (ARGV[i] == name) return true;
	return false;
}

// section(title, body) — единый вид секции. Пустое тело подписываем явно: «пусто» — это факт
// (например, молчащий watchdog — норма), а не повод оставить читателя в неведении.
function section(title, body) {
	let b = trim(body ?? "");
	return sprintf("──── %s ────\n%s\n\n", title, length(b) > 0 ? b : "(пусто)");
}

let cfg = {};
let raw_cfg = readfile(CFG_FILE);
if (raw_cfg != null) {
	try { cfg = json(raw_cfg) ?? {}; } catch (e) { cfg = {}; }
}
let protocol = cfg.protocol ?? "awg";
let tun_if = tunnel_info(protocol).tunnel_if;

// ── железо и версии ──────────────────────────────────────────────────────────
// Одним батчем: каждый форк на слабом роутере заметен, а полей нужно много.
let env = sh(
	"echo \"date=$(date '+%Y-%m-%d %H:%M:%S %Z')\"; " +
	"echo \"uptime=$(uptime 2>/dev/null | sed 's/^ *//')\"; " +
	"echo \"model=$(ubus call system board 2>/dev/null | grep -o '\"model\": *\"[^\"]*\"' | head -1)\"; " +
	"echo \"release=$(. /etc/openwrt_release 2>/dev/null; echo $DISTRIB_RELEASE $DISTRIB_TARGET)\"; " +
	"echo \"arch=$(uname -m)\"; " +
	"echo \"kernel=$(uname -r)\"; " +
	"echo \"ram=$(awk '/MemTotal/{printf \"%d\", $2/1024}' /proc/meminfo 2>/dev/null) МБ, свободно " +
		"$(awk '/MemAvailable/{printf \"%d\", $2/1024}' /proc/meminfo 2>/dev/null) МБ\"; " +
	"echo \"flash=$( (df -k /overlay 2>/dev/null || df -k /) | awk 'NR>1{for(i=1;i<=NF;i++) " +
		"if ($i ~ /^[0-9]+$/) {n++; if (n==3) {printf \"%d\", $i/1024; exit}}}' ) МБ свободно\"; " +
	"echo \"singbox=$(sing-box version 2>/dev/null | head -1)\"; " +
	"echo \"cheburnet=$(apk list -I 2>/dev/null | grep -m1 '^cheburnet-' || echo '(пакет не найден)')\"; " +
	"true"
);

// ── состояние туннеля и сервисов ─────────────────────────────────────────────
let state = sh(
	sprintf("echo '--- интерфейс %s ---'; ip addr show dev %s 2>&1 | head -6; ", tun_if, tun_if) +
	"echo '--- AmneziaWG ---'; awg show 2>&1 | head -20; " +
	"echo '--- сервисы ---'; " +
	"for s in dnsmasq https-dns-proxy sing-box; do " +
	"  printf '%s: ' \"$s\"; /etc/init.d/$s status 2>/dev/null || echo '(нет такого сервиса)'; done; " +
	"echo '--- маршруты по умолчанию и таблицы ---'; ip -4 route show 2>&1 | head -12; " +
	"echo '--- правила policy routing ---'; ip -4 rule show 2>&1 | head -12; " +
	// Домены считаем, а не печатаем: список бывает в тысячи строк, и он говорит о том, что человек
	// открывает. В диагностике нужен размер, а не содержимое.
	"echo '--- nft-наборы (размер) ---'; " +
	"for set in direct direct6; do " +
	"  printf 'inet fw4 %s: ' \"$set\"; " +
	"  nft -j list set inet fw4 $set 2>/dev/null | grep -o '\"elem\"' | wc -l || echo '?'; done; " +
	"true"
);

let install_log = sh(sprintf("tail -c %d %s 2>/dev/null", INSTALL_LOG_TAIL_BYTES, LOG_FILE));

// Системный журнал — только строки про наш стек: в общем logread шум забивает сигнал, а читать
// это человеку.
let syslog = sh(sprintf(
	"logread 2>/dev/null | grep -E 'cheburnet|sing-box|dnsmasq|https-dns-proxy|netifd|amneziawg|awg|firewall' " +
	"| tail -%d", SYSLOG_TAIL_LINES));

// Конфигурация: в install.json секретов нет по построению (см. rpcd-cheburnet), но пропускаем
// через redact вместе со всем остальным — на случай, если однажды туда что-то попадёт.
let cfg_lines = [
	sprintf("протокол: %s", protocol),
	sprintf("режим: %s", cfg.mode ?? "(нет)"),
	sprintf("доменов прямого доступа (свои): %d", length(cfg.user_domains ?? [])),
	sprintf("DNS-провайдер: %s", cfg.dns_provider ?? "(нет)"),
	sprintf("установлено с пропуском проверок железа: %s",
		length(cfg.forced ?? []) > 0 ? join(", ", cfg.forced) : "нет"),
];

let body =
	section("роутер и версии", env) +
	section("конфигурация (без секретов)", join("\n", cfg_lines)) +
	section("состояние сети и сервисов", state) +
	section(sprintf("журнал установки (последние %d КБ)", INSTALL_LOG_TAIL_BYTES / 1000), install_log) +
	section(sprintf("системный журнал, наши сервисы (последние %d строк)", SYSLOG_TAIL_LINES), syslog);

let r = redact(body);

// Шапка идёт ПОСЛЕ чистки и не проходит через неё: иначе список вырезанного сам мог бы попасть
// под правило и стать нечитаемым.
let removed_line = length(r.removed) > 0
	? "Вырезано перед сохранением: " + join("; ", r.removed) + "."
	: "Секретов известных форм в этом пакете не нашлось.";

let head = "════ cheburnet — диагностика ════\n" +
	removed_line + "\n" +
	"Адрес и порт вашего сервера оставлены намеренно: подключиться по ним нельзя, а без них\n" +
	"причину не найти. Перед отправкой пролистайте файл — вы отправляете именно то, что видите.\n\n";

if (has_flag("--json")) {
	print(sprintf("%J\n", { text: head + r.text, removed: r.removed }));
} else {
	print(head + r.text);
}
