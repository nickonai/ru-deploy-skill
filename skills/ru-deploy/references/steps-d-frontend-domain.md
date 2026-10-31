# Стадия D: фронт и домен (шаги 5-6)

Ворота после стадии D остаются в `SKILL.md` и обязательны.

## Шаг 5. Фронт на новый адрес

Минимальная правка кода в проекте — только адрес и ключ backend. **Оба значения должны точно совпадать с серверными**, иначе сайт не подключится.

1. В `src/integrations/supabase/client.ts`:
   - если URL/ключ читаются из `import.meta.env` — создай `.env` в корне:
     ```
     VITE_SUPABASE_URL=https://<домен>
     VITE_SUPABASE_PUBLISHABLE_KEY=<ANON_KEY с шага 2>
     ```
   - если они **зашиты прямо в коде** — замени значения на новый домен и `ANON_KEY` (или перепиши на чтение из `import.meta.env`).

   **Критично — ключ должен совпадать с серверным `ANON_KEY`.** `VITE_SUPABASE_PUBLISHABLE_KEY` — это и есть серверный `ANON_KEY` (его печатает `server-setup.sh`). Если во фронте останется ключ от другого/старого сервера, Kong ответит `401 Unauthorized`, а в браузере это выглядит как `Failed to fetch`. Сверь явно перед сборкой: `RSH "sudo grep '^ANON_KEY=' /opt/supabase/docker/.env"` → это значение и должно стоять в `VITE_SUPABASE_PUBLISHABLE_KEY`. (Скрипт заливки сам сверяет адрес и ключ с сервером до сборки и остановится с подсказкой, если не совпало.)
2. Собери и залей фронт:
   ```bash
   set -a; . .ru-deploy/credentials.env; set +a
   RU_HOST="$RU_HOST" RU_USER="$RU_USER" RU_PASS="$RU_PASS" bash "$SKILL_DIR/assets/deploy.sh" frontend "$RU_DOMAIN"
   ```
   (скрипт делает `npm run build` и копирует `dist/` в `/var/www/app` на сервере; Caddy уже раздаёт эту папку).

Проверка: открой `https://<домен>` — сайт грузится, существующий пользователь входит. **Новая регистрация заработает только после настройки почты (шаг 7)** — по умолчанию вход требует подтверждения email (безопасно), а письма уходят лишь когда настроен SMTP. Если проекту нужно проверить регистрацию прямо сейчас, до почты — backend можно поднять с временным `EMAIL_AUTOCONFIRM=true` (см. `references/backend-supabase.md` → «Безопасные дефолты»), но в боевом режиме это потом верни в `false`.

## Шаг 6. Домен и HTTPS

Caddy ставится и настраивается на шаге 2 и **сам** получает бесплатный сертификат Let's Encrypt, как только DNS указывает на сервер. Отдельных действий обычно не нужно. Если сертификат не выдался — `references/cloudru-setup.md` → «HTTPS не поднялся».

### Смена домена (sslip.io → свой .ru, или любой другой)

Запускается, когда пользователь переходит с временного `<IP>.sslip.io` на настоящий домен (или меняет домен). **Домен зашит в ТРЁХ местах — поменяй все, иначе фронт будет стучаться по старому адресу и упадёт с `Failed to fetch`.** Это частый баг: поменяли в одном месте, забыли в других.

Сделай по порядку:

1. **Убедись, что новый домен указывает на сервер** (A-запись на IP) и порты 80/443 открыты — иначе Caddy не выдаст сертификат на новый домен. Проверка: `ping <новый-домен>` → IP сервера.
2. **Сервер — все серверные URL разом** (готовый скрипт, чтобы не забыть ни одну переменную):
   ```bash
   set -a; . .ru-deploy/credentials.env; set +a
   export SSHPASS="$RU_PASS"
   sshpass -e scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.ru-deploy/known_hosts \
     "$SKILL_DIR/assets/set-domain.sh" "$RU_USER@$RU_HOST:~/"
   RSH "bash ~/set-domain.sh <новый-домен>"
   ```
   Скрипт меняет `SITE_URL`, `API_EXTERNAL_URL`, `SUPABASE_PUBLIC_URL`, `ADDITIONAL_REDIRECT_URLS`, перенастраивает Caddy на новый домен и перезапускает `auth`+`kong`.
3. **Фронт — обнови адрес и ПЕРЕСОБЕРИ** (адрес backend вшивается в сборку, без пересборки в JS останется старый):
   - в локальном `.env` проекта: `VITE_SUPABASE_URL=https://<новый-домен>` (если адрес зашит прямо в `src/integrations/supabase/client.ts` — поправь там);
   - обнови `RU_DOMAIN` в `.ru-deploy/credentials.env`;
   - пересобери и залей: `RU_HOST="$RU_HOST" RU_USER="$RU_USER" RU_PASS="$RU_PASS" bash "$SKILL_DIR/assets/deploy.sh" frontend "<новый-домен>"`.
4. **Проверь** (через ~30 сек после перезапуска): `https://<новый-домен>` открывается, вход работает, в консоли браузера нет `Failed to fetch`. Со стороны сервера: `curl -sS -o /dev/null -w '%{http_code} TLS=%{ssl_verify_result}\n' https://<новый-домен>/auth/v1/health` → `200 TLS=0`.
5. **Старый `sslip.io`-домен** после смены перестаёт обслуживаться Caddy — это нормально, ссылки на него больше не используются.

Подробный чек-лист «где встречается домен» — в `references/troubleshooting.md` → «Failed to fetch после смены домена».
