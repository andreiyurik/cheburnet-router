// assemble.uc — CLI чистой сборки списка: { user, imported_text } (stdin JSON) → домены + stats.
//
//   echo '{"user":["mine.example"],"imported_text":"a.example\nb.example\n"}' | ucode -R assemble.uc
//
// Локально тестируется без роутера. На роутере imported_text = содержимое кэша из fetch.uc;
// результат domains → routing.build_plan → DNS-шаг.

import { stdin } from "fs";
import { assemble } from "./list.uc";

let raw = trim(stdin.read("all") ?? "");
let req = (substr(raw, 0, 1) == "{") ? json(raw) : {};
let r = assemble(req.user, req.imported_text, req.opts);
print(sprintf("%J\n", r));
