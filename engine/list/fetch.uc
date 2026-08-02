// fetch.uc — загрузка community-списка по сети (импурно, router-side).
//
//   ucode -R fetch.uc [url] [cache]    # url по умолчанию — DEFAULT_SOURCE (list.uc),
//                                      # cache по умолчанию /etc/cheburnet/direct-list
//
// ИНВАРИАНТ: атомарная замена кэша (rename), только если скачанное ПОХОЖЕ на список доменов —
// иначе прежний кэш остаётся, а fetch падает (лучше старый рабочий список, чем 404/captive-portal
// мусором). Проверяется в QEMU; sanity-логика (looks_like_list) — под юнит-тестами list.

import { popen, readfile, rename, unlink } from "fs";
import { looks_like_list, DEFAULT_SOURCE } from "./list.uc";

const MIN_VALID = 10; // ниже — считаем, что скачался мусор, а не список

function sh(cmd) {
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

// Без аргумента — дефолтный источник (контракт ubus update_list: «без url есть дефолт»).
let url = (length(ARGV) > 0 && length(ARGV[0]) > 0) ? ARGV[0] : DEFAULT_SOURCE;
let cache = (length(ARGV) > 1) ? ARGV[1] : "/etc/cheburnet/direct-list";

let tmp = cache + ".tmp";
// -T обязателен: без таймаута busybox-wget/uclient-fetch висят на мёртвом соединении, а нас ждёт rpcd.
sh(sprintf("uclient-fetch -T 15 -q -O '%s' '%s' 2>/dev/null || wget -T 15 -q -O '%s' '%s' 2>/dev/null",
	tmp, url, tmp, url));

let text = readfile(tmp);
if (text == null || !looks_like_list(text, MIN_VALID)) {
	unlink(tmp); // нет файла/уже удалён — ошибку игнорируем
	die(sprintf("fetch: ответ не похож на список доменов (нужно ≥%d валидных) — кэш не тронут", MIN_VALID));
}

// rename, не truncate+write: обрыв питания посреди записи не должен оставить битый кэш.
if (rename(tmp, cache) != true)
	die(sprintf("fetch: не смог заменить кэш %s — список не обновлён", cache));
printf("fetch: список обновлён из %s → %s\n", url, cache);
