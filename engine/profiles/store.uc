// store.uc — хранилище профилей на роутере (импурно): profiles.json (без секретов) + profiles/<id>.conf (600).
// Логика — profiles.uc (чисто). Зовут rpcd-cheburnet, install/replace_vpn.uc, install/run.uc, watchdog/tick.uc.

import { readfile, writefile, unlink, chmod, mkdir, rename } from "fs";
import { normalize, find, add, mark_active } from "./profiles.uc";

function etc() { return getenv("ETC_CHEBURNET") ?? "/etc/cheburnet"; }
function index_file() { return etc() + "/profiles.json"; }
function conf_dir() { return etc() + "/profiles"; }

// conf_path(id) — id только из нашего счётчика (p<N>, проверено normalize), не из ввода.
function conf_path(id) { return sprintf("%s/%s.conf", conf_dir(), id); }

function load() {
	let raw = readfile(index_file());
	let parsed = null;
	if (raw && substr(trim(raw), 0, 1) == "{")
		try { parsed = json(raw); } catch (e) { parsed = null; }
	return normalize(parsed);
}

// save(st) — через временный файл + rename: оборванная запись (питание) не оставит битый JSON.
function save(st) {
	mkdir(etc(), 0o700);
	let tmp = index_file() + ".tmp";
	writefile(tmp, sprintf("%J\n", st));
	rename(tmp, index_file());
}

function read_conf(id) {
	return readfile(conf_path(id));
}

// write_conf(id, text) — права 0600 ДО записи: приватный ключ не лежит ни мгновения с umask-правами.
function write_conf(id, text) {
	mkdir(conf_dir(), 0o700);
	let p = conf_path(id);
	writefile(p, "");
	chmod(p, 0o600);
	writefile(p, text);
}

function drop_conf(id) {
	unlink(conf_path(id));
}

// commit_conf(conf, id, auto_switch) — сервер ПОДТВЕРЖДЁН handshake'ом: запомнить его активным.
// Контракт: id задан → его .conf = conf, профиль становится активным; id=null (ручная замена
// конфига, установка мастером) → перезаписать .conf активного, а нет активного — завести «Сервер N».
function commit_conf(conf, id, auto_switch) {
	let st = load();
	if (id && find(st, id)) {
		write_conf(id, conf);
		save(mark_active(st, id, time(), auto_switch));
		return id;
	}
	if (st.active) {
		write_conf(st.active, conf);
		return st.active;
	}
	let r = add(st, sprintf("Сервер %d", st.next_id));
	if (!r.ok) return null; // 16 профилей и нет активного — текущий сервер просто не сохраняем
	write_conf(r.id, conf);
	save(mark_active(r.state, r.id, time(), false));
	return r.id;
}

// clear_active() — подтверждён туннель НЕ на AWG: ни один профиль больше не подключён. ШРАМ (ревью):
// устаревший active потом молча перезаписывался чужим .conf при возврате на AWG и не давал удалить
// профиль, который панель показывала неподключённым.
function clear_active() {
	let st = load();
	if (!st.active) return;
	st.active = null;
	save(st);
}

export { load, save, read_conf, write_conf, drop_conf, conf_path, commit_conf, clear_active };
