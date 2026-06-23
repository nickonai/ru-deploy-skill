# Платежи YooKassa

**Цель документа:** перевести оплату через YooKassa на новый сервер — стадия F. Нужен, только если в проекте есть оплата (функции вроде `create-payment`, `*-webhook`).

**Что делает агент:**
1. Просит у пользователя `shopId` и секретный ключ YooKassa, прописывает их в `.env`.
2. Меняет `return_url` в коде платёжной функции со старого `*.lovable.app` на новый домен.
3. Делает вебхук-функцию публичной через `PUBLIC_FUNCTIONS` в серверном `.env` (точечно), просит пользователя зарегистрировать URL вебхука в кабинете YooKassa.
4. Добавляет перепроверку статуса платежа через YooKassa API (защита от подделки).
5. Проверяет: тестовый платёж проходит, заказ в базе становится `paid`.

> **Команды `ssh root@<IP>`** здесь — сокращение. Используй хелпер `RSH` (логин пользователя + `sshpass`, см. SKILL.md → «Доступы к серверу»), а запись в `/opt` и `docker` — через `sudo`.

## Как это работает (3 части)

1. **Создание платежа** (`create-payment`): фронт зовёт функцию → она ходит в `api.yookassa.ru` с твоими `shopId`/секретом → возвращает ссылку на оплату → фронт перенаправляет пользователя.
2. **Возврат пользователя** после оплаты — на `return_url` (страница «успешно»).
3. **Вебхук** (`yookassa-webhook`): YooKassa сама шлёт POST на твой сервер, когда платёж прошёл → функция помечает заказ оплаченным.

## Что делает пользователь

1. В личном кабинете YooKassa (Настройки магазина) берёт **shopId** и **секретный ключ**, присылает тебе.
2. Регистрирует **URL уведомлений (вебхук)**:
   `https://<домен>/functions/v1/<имя-webhook-функции>` (имя возьми из `supabase/functions/`),
   событие — `payment.succeeded` (и при желании `payment.canceled`).

## Что делаешь ты (агент)

### 1. Секреты на сервер
```bash
RSH "sudo tee -a /opt/supabase/docker/.env >/dev/null" <<'EOF'
YOOKASSA_SHOP_ID=...
YOOKASSA_SECRET_KEY=...
EOF
RSH "cd /opt/supabase/docker && sudo docker compose up -d functions"
```

### 2. Поменять return_url в коде
Найди в функции создания платежа захардкоженный адрес возврата (часто `https://...lovable.app/...`) и замени на новый домен. Пример:
```diff
- return_url: return_url || "https://my-app.lovable.app/payment-success",
+ return_url: return_url || "https://<домен>/payment-success",
```
Перезалей функции (`deploy.sh functions`).

### 3. Открыть вебхуку доступ без JWT (точечно, через PUBLIC_FUNCTIONS)

По умолчанию backend поднят с `FUNCTIONS_VERIFY_JWT=true` — это защита: edge-функции требуют токен. Но YooKassa зовёт вебхук **без токена**, поэтому именно вебхук-функцию надо сделать публичной — **точечно, не снимая защиту со всех функций**.

⚠️ **Пометка `// verify_jwt = false` в коде функции на self-hosted НЕ работает** — штатный роутер `main` проверяет JWT глобально и эту строку игнорирует (это рабочий способ в облачном Supabase, но не здесь). Вместо неё добавь имя вебхук-функции в список `PUBLIC_FUNCTIONS` в серверном `.env` — его читает патч-роутер `functions-main.ts`, который ставит `server-setup.sh`:
```bash
set -a; . .ru-deploy/credentials.env; set +a
RSH "sudo sed -i 's/^PUBLIC_FUNCTIONS=.*/PUBLIC_FUNCTIONS=<имя-webhook>/' /opt/supabase/docker/.env"
RSH "cd /opt/supabase/docker && sudo docker compose up -d functions"
```
(несколько публичных функций — через запятую: `PUBLIC_FUNCTIONS=hook1,hook2`). Функции, требующие авторизации (например `create-payment`, который зовёт фронт с токеном пользователя), в список НЕ добавляй — так открыт ровно один публичный вход. Проверь, что вебхук теперь отвечает без токена: `curl -i https://<домен>/functions/v1/<имя-webhook>` (не должно быть `401 Missing authorization header`).

> Глобально выключать (`FUNCTIONS_VERIFY_JWT=false`) не нужно и опасно — это открыло бы без токена *все* функции, включая те, что работают с деньгами и данными.

### 4. Защитить вебхук (ОБЯЗАТЕЛЬНО для реальных денег)

Типовой Lovable-вебхук **доверяет телу запроса** — кто угодно может прислать `{"event":"payment.succeeded", ...}` и бесплатно получить премиум. YooKassa вебхуки не подписывает, поэтому правильное решение — **перепросить статус у YooKassa по ID платежа**, прежде чем что-либо менять в базе.

Вставь в начало обработки вебхука (после получения `payment.id`) проверку:
```ts
// Перепроверяем платёж напрямую у YooKassa — не доверяем телу запроса
const shopId = Deno.env.get("YOOKASSA_SHOP_ID")!;
const secretKey = Deno.env.get("YOOKASSA_SECRET_KEY")!;
const check = await fetch(`https://api.yookassa.ru/v3/payments/${payment.id}`, {
  headers: { Authorization: "Basic " + btoa(`${shopId}:${secretKey}`) },
});
if (!check.ok) {
  return new Response(JSON.stringify({ error: "verify failed" }), { status: 400 });
}
const real = await check.json();
// дальше используем real.status / real.metadata, а НЕ значения из тела запроса
const status = real.status === "succeeded" ? "paid"
             : real.status === "canceled" ? "canceled" : "pending";
const userId = real.metadata?.user_id;
```
Дополнительно можно ограничить доступ к вебхуку диапазонами IP YooKassa (их список — в документации YooKassa).

## Проверка

YooKassa даёт тестовый магазин/карты. Сделай тестовую оплату → пользователь возвращается на свой домен → заказ в базе становится `paid` (проверь: `RSH "sudo docker exec -i supabase-db psql -U postgres -d postgres -c 'select * from orders order by created_at desc limit 5;'"`).
