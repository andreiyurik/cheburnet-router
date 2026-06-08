// fetch.uc — загрузка community-списка по сети (импурно, router-side).
//
//   ucode -R fetch.uc <url> [cache]    # cache по умолчанию /etc/cheburnet/direct-list
//
// Скачивает список во временный файл, проверяет, что это ПОХОЖЕ на список доменов (защита от
// 404/captive-portal), и только тогда атомарно заменяет кэш. Иначе — оставляет прежний кэш и
// падает: лучше старый рабочий список, чем затереть его мусором (vendored/cached-fallback, v1).
// Проверяется в QEMU; sanity-логика (looks_like_list) — под юнит-тестами list.

import { popen, readfile, writefile, unlink } from "fs";
import { looks_like_list } from "./list.uc";

const MIN_VALID = 10; // ниже — считаем, что скачался мусор, а не список

function sh(cmd) {
	let p = popen(cmd, "r");
	if (!p) return "";
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

let url = (length(ARGV) > 0) ? ARGV[0] : "";
let cache = (length(ARGV) > 1) ? ARGV[1] : "/etc/cheburnet/direct-list";
if (length(url) == 0)
	die("fetch: нужен URL (ucode -R fetch.uc <url> [cache])");

let tmp = cache + ".tmp";
// uclient-fetch штатен на OpenWrt; wget — fallback. -O пишет в файл, тихо.
sh(sprintf("uclient-fetch -q -O '%s' '%s' 2>/dev/null || wget -q -O '%s' '%s' 2>/dev/null",
	tmp, url, tmp, url));

let text = readfile(tmp);
if (text == null || !looks_like_list(text, MIN_VALID)) {
	unlink(tmp); // нет файла/уже удалён — ошибку игнорируем
	die(sprintf("fetch: ответ не похож на список доменов (нужно ≥%d валидных) — кэш не тронут", MIN_VALID));
}

// Атомарная замена: пишем проверенный текст в кэш (writefile перезаписывает целиком).
writefile(cache, text);
unlink(tmp);
printf("fetch: список обновлён из %s → %s\n", url, cache);
