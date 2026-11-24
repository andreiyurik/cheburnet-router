// recover.uc — откатить установку, прерванную перезагрузкой или падением (импурно).
//   ucode -R recover.uc   # 0 — откатывать нечего или откат выполнен
// Зовут reapply.uc (hotplug после загрузки) и rpcd status (человек открыл страницу).
// Метка install.pending есть, а процесса установки нет → снимок на флеше вернёт «как было».

import { readfile, unlink, access, mkdir, rmdir } from "fs";
import { sh, run_stdin } from "../lib/proc.uc";

const ETC = getenv("ETC_CHEBURNET") ?? "/etc/cheburnet";
const STATE_DIR = getenv("STATE_DIR") ?? "/tmp/cheburnet";
const PENDING = ETC + "/install.pending";
const LOCK = STATE_DIR + "/recover.lock";
let ENGINE = getenv("ENGINE_DIR") ?? (sourcepath(0, true) + "/..");

function installer_alive() {
	if (access(STATE_DIR + "/done")) return false;
	let pid = trim(readfile(STATE_DIR + "/pid") ?? "");
	return length(pid) > 0 && trim(sh(sprintf("kill -0 %s 2>/dev/null; echo $?", pid))) == "0";
}

let raw = readfile(PENDING);
// Установка идёт прямо сейчас (hotplug дёргается её network restart'ом) — не мешаем.
if (raw == null || installer_alive())
	exit(0);

// Замок: status могут спросить параллельно, а откат должен выполниться один раз.
sh(sprintf("mkdir -p %s", STATE_DIR));
if (mkdir(LOCK) !== true)
	exit(0);
// Метку снимаем ДО отката: run.uc --rollback зовёт reapply.uc, а тот — снова нас.
unlink(PENDING);
sh("logger -t cheburnet 'установка была прервана — возвращаю роутер в состояние до неё'");
let rc = run_stdin(sprintf("ucode -R %s/install/run.uc --rollback", ENGINE), raw);
rmdir(LOCK);
exit(rc == 0 ? 0 : 1);
