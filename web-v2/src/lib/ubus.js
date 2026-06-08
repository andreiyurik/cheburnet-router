// ubus.js — клиент ubus JSON-RPC поверх uhttpd-mod-ubus (роутер отдаёт /ubus).
//
// Веб-мастер общается с движком (объект `cheburnet`, см. engine/ubus) через ubus. До установки
// у пользователя нет сессии — ходим с НУЛЕВОЙ сессией; ACL пакета даёт анониму read + install
// (мутация гейтится install-токеном). Пост-установочные методы (set_mode/update_list) требуют
// авторизованной сессии — здесь не используются в install-flow.

const UBUS_URL = '/ubus';
const NULL_SESSION = '00000000000000000000000000000000';

let nextId = 1;

// Коды результата ubus (status в первом элементе result-кортежа).
const UBUS_STATUS = {
  0: 'OK',
  2: 'INVALID_ARGUMENT',
  4: 'METHOD_NOT_FOUND',
  6: 'PERMISSION_DENIED',
  7: 'TIMEOUT',
  9: 'NOT_FOUND',
};

// call(object, method, params) → данные ответа метода. Бросает Error с понятным текстом при
// сетевой/JSON-RPC/ubus-ошибке — экраны ловят и показывают пользователю.
export async function call(object, method, params = {}) {
  const body = {
    jsonrpc: '2.0',
    id: nextId++,
    method: 'call',
    params: [NULL_SESSION, object, method, params],
  };

  let res;
  try {
    res = await fetch(UBUS_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  } catch (e) {
    throw new Error(`сеть недоступна: ${e.message}`);
  }
  if (!res.ok) throw new Error(`HTTP ${res.status} от /ubus`);

  const json = await res.json();
  if (json.error) throw new Error(`ubus RPC: ${json.error.message ?? json.error.code}`);

  // result = [status, data]. status != 0 → ubus отклонил вызов (права/метод/аргументы).
  const [status, data] = json.result ?? [];
  if (status !== 0) {
    const label = UBUS_STATUS[status] ?? `код ${status}`;
    throw new Error(`ubus отклонил вызов: ${label}`);
  }

  // Наши обработчики возвращают {error: "..."} при доменной ошибке (валидация/токен) — поднимаем.
  if (data && data.error) throw new Error(data.error);
  return data ?? {};
}

// Шорткат к нашему объекту движка.
export const cheburnet = (method, params) => call('cheburnet', method, params);
