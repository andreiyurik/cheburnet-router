// redact.uc — вырезание секретов из диагностического текста (ЧИСТАЯ функция, под юнит-тестами).
//
//   import { redact, MASK } from "../lib/redact.uc";
//   let r = redact(text);   // → { text, removed: ["ключи туннеля", ...] }
//
// ЗАЧЕМ. Пользователь отправляет диагностику в мессенджер, чтобы ему помогли. Без чистки он
// вместе с логами отдаёт РАБОЧИЕ ключи от своего VPN и пароль домашнего Wi-Fi — третьему
// сервису, где они закешируются и уедут дальше. Причём человек уверен, что «просто отправил
// логи». Поэтому чистка не опция, а часть сборки пакета.
//
// Адрес и порт сервера НЕ вырезаем: подключиться по ним нельзя, а без них диагноз невозможен.
// removed[] возвращаем, чтобы UI мог назвать, что именно убрано — обещание «мы всё вычистили»
// без списка проверить нельзя, а список человек сверяет с текстом сам.
//
// ⚠ ucode/POSIX-ERE: внутри [...] НЕ работают \s, \d и (?:…) — группировка без захвата тоже
// не поддерживается (синтаксическая ошибка). `\s` внутри класса становится литералами `\` и `s`,
// то есть шаблон молча исключает букву «s» и перестаёт находить пароли с ней. Поэтому здесь
// только [[:space:]] и обычные (захватывающие) группы.

const MASK = "<удалено>";

// Правила чистки. Каждое — { label, apply }: label попадёт в removed[], если правило что-то
// изменило. Пересечения правил допустимы: лишняя маскировка безопасна, пропущенный секрет — нет.
const RULES = [
	{
		// WireGuard/AmneziaWG .conf: приватный и пресхаред-ключ.
		label: "ключи туннеля",
		apply: function(t) {
			return replace(t, /(PrivateKey|PresharedKey)([[:space:]]*=[[:space:]]*)[^[:space:]]+/g,
				(m, a, b) => a + b + MASK);
		},
	},
	{
		// Ключ WireGuard в чистом виде (32 байта base64) — ловим, даже если он попал в лог
		// без имени поля: вывод `awg show`, дампы конфига, сообщения об ошибках.
		label: "ключи туннеля",
		apply: function(t) {
			return replace(t, /[A-Za-z0-9+\/]{43}=/g, MASK);
		},
	},
	{
		// Учётная часть ссылки до «@»: пароль Hysteria2, UUID у VLESS.
		label: "пароли из ссылок",
		apply: function(t) {
			return replace(t, /([a-z0-9]+:\/\/)[^@[:space:]\/]+@/g, (m, a) => a + MASK + "@");
		},
	},
	{
		// Параметры ссылки: pbk/sid у Reality, пароль обфускации у Hysteria2.
		label: "параметры ссылок (pbk, sid, пароли обфускации)",
		apply: function(t) {
			return replace(t, /([?&](pbk|sid|obfs-password|obfs_password|password|passwd|key|auth)=)[^&[:space:]]+/g,
				(m, a) => a + MASK);
		},
	},
	{
		// JSON-конфиг sing-box: попадает в лог целыми строками при провале `sing-box check`.
		label: "пароли и ключи из конфигов",
		apply: function(t) {
			return replace(t, /("(private_key|password|passwd|psk|obfs|auth|key)"[[:space:]]*:[[:space:]]*")[^"]*"/g,
				(m, a) => a + MASK + '"');
		},
	},
	{
		// UCI: wireless.*.key='…' (пароль Wi-Fi), root_password, password в кавычках.
		// Регистр важен: PublicKey/PrivateKey не совпадут с lowercase `key` — приватный ключ
		// ловится правилом выше, а публичный оставляем (он не секрет).
		label: "пароль Wi-Fi",
		apply: function(t) {
			return replace(t, /((key|wifi_key|root_password|password)[[:space:]]*=?[[:space:]]*['"])[^'"]*(['"])/g,
				(m, a, b, c) => a + MASK + c);
		},
	},
	{
		// UUID пользователя VLESS — идентификатор доступа к серверу.
		label: "UUID",
		apply: function(t) {
			return replace(t, /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g, MASK);
		},
	},
];

// redact(text) → { text, removed }. removed — метки сработавших правил без повторов, в порядке
// правил (стабильный вывод: UI показывает один и тот же список при том же входе).
function redact(text) {
	let t = (type(text) == "string") ? text : "";
	let removed = [];
	for (let i = 0; i < length(RULES); i++) {
		let before = t;
		t = RULES[i].apply(t);
		if (t != before && index(removed, RULES[i].label) < 0)
			push(removed, RULES[i].label);
	}
	return { text: t, removed: removed };
}

export { redact, MASK };
