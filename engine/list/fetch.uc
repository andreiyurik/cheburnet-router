// fetch.uc — загрузка community-списка по сети (импурно, router-side).
//
//   ucode -R fetch.uc [url] [cache]    # url по умолчанию — DEFAULT_SOURCE (list.uc),
//                                      # cache по умолчанию /etc/cheburnet/direct-list
//
// Скачивает список во временный файл, проверяет, что это ПОХОЖЕ на список доменов (защита от
// 404/captive-portal), и только тогда атомарно заменяет кэш. Иначе — оставляет прежний кэш и
// падает: лучше старый рабочий список, чем затереть его мусором (vendored/cached-fallback, v1).
// Проверяется в QEMU; sanity-логика (looks_like_list) — под юнит-тестами list.

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
// uclient-fetch штатен на OpenWrt; wget — fallback. -T обязателен: без таймаута busybox-wget/
// uclient-fetch висят на мёртвом соединении (урок однострочника README) — а нас ждёт rpcd.
sh(sprintf("uclient-fetch -T 15 -q -O '%s' '%s' 2>/dev/null || wget -T 15 -q -O '%s' '%s' 2>/dev/null",
	tmp, url, tmp, url));

let text = readfile(tmp);
if (text == null || !looks_like_list(text, MIN_VALID)) {
	unlink(tmp); // нет файла/уже удалён — ошибку игнорируем
	die(sprintf("fetch: ответ не похож на список доменов (нужно ≥%d валидных) — кэш не тронут", MIN_VALID));
}

// Атомарная замена: rename tmp→cache (тот же каталог = та же ФС). truncate+write здесь нельзя:
// обрыв питания посреди записи оставил бы битый кэш («годы без обслуживания» этого не прощают).
if (rename(tmp, cache) != true)
	die(sprintf("fetch: не смог заменить кэш %s — список не обновлён", cache));
printf("fetch: список обновлён из %s → %s\n", url, cache);
