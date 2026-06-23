# Backend: self-hosted Supabase на сервере

**Цель документа:** поднять backend (Supabase) на сервере, накатить схему базы и залить edge-функции (стадия C, шаги 2-4).

**Что делает агент:**
1. Заливает на сервер `server-setup.sh` (+ `gen-keys.py`, `Caddyfile`, `patch-compose.py`, `functions-main.ts`) и запускает его — стек поднимается сам, с патч-роутером функций и пропатченным compose.
2. Применяет миграции из `supabase/migrations/`, **проверяет, что таблицы создались** (`\dt public.*`), при необходимости бэкафиллит профили существующих пользователей.
3. Заливает edge-функции через `deploy.sh functions`, прописывает их секреты в `.env`; для публичных вебхуков — заносит имя в `PUBLIC_FUNCTIONS`.
4. Проверяет, что API отвечает по HTTPS и схема на месте, и подтверждает результат пользователю.

Всю серверную работу делает агент; пользователю оставляй только то, что требует его рук (ключи из кабинетов).

> **Как читать команды `ssh root@<IP> "..."`.** В примерах ниже для краткости написано `ssh root@<IP>` и `docker ...`. На реальной Cloud.ru-ВМ:
> - подставляй **логин пользователя**, а не `root`, и заходи через `sshpass` с его паролем — удобнее через хелпер `RSH` из SKILL.md → «Доступы к серверу» (`set -a; . .ru-deploy/credentials.env; set +a`, далее `RSH "..."`);
> - системные/`docker` команды на сервере выполняй через **`sudo`** (`sudo docker ...`).
>
> То есть `ssh root@<IP> "docker compose ps"` на практике = `RSH "cd /opt/supabase/docker && sudo docker compose ps"`. Скрипты `server-setup.sh`/`deploy.sh` это уже делают сами.

## Что куда ложится на сервере

| Путь на сервере | Что это |
|---|---|
| `/opt/supabase/docker/` | стек Supabase (docker-compose) |
| `/opt/supabase/docker/.env` | **все серверные секреты** (ключи, SMTP, YooKassa, AI) |
| `/opt/supabase/docker/volumes/functions/` | edge-функции |
| `/var/www/app/` | собранный фронтенд (раздаёт Caddy) |
| `/etc/caddy/Caddyfile` | конфиг Caddy |

## Шаг 2. Установка (что делает server-setup.sh)

Скрипт сам: включает swap, ставит Docker, скачивает Supabase, **генерирует все ключи** (`POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `SECRET_KEY_BASE`, `VAULT_ENC_KEY`, пароль дашборда), прописывает домен в `SITE_URL`/`API_EXTERNAL_URL`/`SUPABASE_PUBLIC_URL`, **ставит патч-роутер функций** (`functions-main.ts`, чтобы работали публичные вебхуки) и **патчит `docker-compose.yml`** (`patch-compose.py`: `env_file` для functions + переменные писем для auth), поднимает контейнеры и запускает Caddy с HTTPS.

**Облегчённый стек.** Скрипт поднимает не весь Supabase, а только нужное простому проекту: `db, kong, auth, rest, storage, imgproxy, functions, meta, studio`. Сознательно **не запускаются** `supavisor` (пул соединений — для нагрузки, у нас падал), `realtime` (websocket-подписки), `analytics`/`vector` (сбор логов, прожорливы по RAM). Это экономит память на free-tier и убирает частые ошибки. Если проекту реально нужен realtime (живые подписки в коде) — добавь `realtime` в запуск: `RSH "cd /opt/supabase/docker && sudo docker compose up -d realtime"`.

Команды (с компьютера пользователя; доступы из `.ru-deploy/credentials.env`):
```bash
set -a; . .ru-deploy/credentials.env; set +a
export SSHPASS="$RU_PASS"   # пароль через env, не в argv
sshpass -e scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.ru-deploy/known_hosts \
  "$SKILL_DIR/assets/server-setup.sh" "$SKILL_DIR/assets/gen-keys.py" "$SKILL_DIR/assets/Caddyfile" \
  "$SKILL_DIR/assets/patch-compose.py" "$SKILL_DIR/assets/functions-main.ts" \
  "$RU_USER@$RU_HOST:~/"
RSH "bash ~/server-setup.sh <домен>"
```
(файлы кладём в домашнюю папку пользователя `~/`, а не в `/root` — у `admin` доступа к `/root` нет.)

В конце скрипт печатает `ANON_KEY` — это `VITE_SUPABASE_PUBLISHABLE_KEY` для фронта (шаг 5). Сохрани.

### Безопасные дефолты (важно)

Скрипт ставит **безопасные значения по умолчанию**, в отличие от типового «всё нараспашку» из туториалов:

- **`FUNCTIONS_VERIFY_JWT=true`** — глобальная проверка токена для edge-функций включена. Если есть **публичный вебхук** (например YooKassa), которому нужен доступ без токена — **не выключай проверку глобально** и **не полагайся на `// verify_jwt = false` в коде** (на self-hosted штатный роутер её игнорирует). Добавь функцию в `PUBLIC_FUNCTIONS` (см. «Публичные функции без JWT» ниже) — патч-роутер пропустит только её.
- **`ENABLE_EMAIL_AUTOCONFIRM=false`** — вход разрешён только после подтверждения email. **Следствие:** пока не настроен SMTP (шаг 7), письма-подтверждения не уходят, и **новый пользователь не сможет зарегистрироваться/войти**. Это нормально — порядок такой: сначала подними backend, затем настрой почту (шаг 7), и регистрация заработает по-настоящему. Если нужно протестировать вход **до** настройки почты — подними с временным autoconfirm: `EMAIL_AUTOCONFIRM=true bash ~/server-setup.sh <домен>`, а после настройки SMTP верни `false` (скрипт e-mail из шага 7 это делает сам). Не оставляй autoconfirm включённым в боевом режиме — иначе кто угодно регистрируется на любой чужой email.

Проверка: `curl -s https://<домен>/rest/v1/ | head` — ответ с ошибкой авторизации означает, что API и HTTPS работают.

### Идемпотентность и «не реставрируй файлы руками»

`server-setup.sh` можно **запускать повторно** — он сам проверяет целостность служебных файлов Supabase (`volumes/api/kong.yml`, `volumes/db/*.sql` и т.п.) и, если установку прерывали и что-то сломалось, перевыкачивает эталонную папку `docker/` из шаблона, **сохраняя данные базы** (`volumes/db/data`) и прописывая ключи в `.env` заново.

**Важное правило: не «восстанавливай» служебные файлы Supabase вручную.** Если контейнер не стартует с ошибкой вроде `not a directory` (Kong, Postgres) или пропал `.env` — это значит, что файлы повреждены (часто Docker создал **директорию** на месте ожидаемого файла). Не чини по одному файлу руками — просто **перезапусти `server-setup.sh`**, он приведёт состояние в порядок целиком. Ручная починка приводит к новым ошибкам: перепутанные ключи, директории вместо файлов, отсутствующий `volumes/functions/main/index.ts`.

Частые симптомы повреждённой установки (всё лечится повторным запуском `server-setup.sh`):
- Kong/Postgres падают: `... not a directory` — служебный файл стал каталогом.
- `docker compose` ругается на пустые переменные — пропал `/opt/supabase/docker/.env`.
- Edge-функции не роутятся — снесли `volumes/functions/main` (системный роутер; проектные функции кладутся рядом, `main` трогать нельзя).

> **Ключи (тонкость нового Supabase).** В свежем `.env` есть поля нового формата `SUPABASE_PUBLISHABLE_KEY`/`SUPABASE_SECRET_KEY` (opaque `sb_...`). **Не заполняй их legacy-JWT** (`ANON_KEY`/`SERVICE_ROLE_KEY`) — Kong увидит дубли и упадёт. Скрипт оставляет их пустыми (тогда работает legacy-режим JWT, который и нужен Lovable-проекту).

### Память: если контейнеры падают

Стек уже облегчён (тяжёлые `supavisor`/`realtime`/`analytics`/`vector` не поднимаются), swap скрипт включил. Если на 4 ГБ что-то всё равно перезапускается (`sudo docker compose ps` показывает restarting) — см. `troubleshooting.md` → «Не хватает памяти».

## Шаг 3. Схема базы (миграции)

Цель — создать те же таблицы/политики, что были в Lovable.

### Вариант А: есть папка `supabase/migrations/` — запусти `apply-migrations.sh`

Применение схемы — **отдельный шаг с самопроверкой**, а не разовая команда между делом (его легко проскочить — именно так в прошлом деплое схема осталась пустой). Запусти из корня проекта:
```bash
set -a; . .ru-deploy/credentials.env; set +a
RU_HOST="$RU_HOST" RU_USER="$RU_USER" RU_PASS="$RU_PASS" bash "$SKILL_DIR/assets/apply-migrations.sh"
```
Скрипт сам делает всё надёжно (доступы берёт из окружения, ходит через одно ssh-соединение):
1. находит `supabase/migrations/*.sql`, применяет их **по порядку имён** (таймстамп = хронология) одним потоком в `psql -v ON_ERROR_STOP=1` (остановка на первой ошибке);
2. **проверяет, что в `public` появились таблицы** — иначе выходит с ошибкой (код `2`). Это и есть гарантия против «пустой базы»: без таблиц сайт открывается, но падает с `Could not find the table 'public.<...>'` при первом входе;
3. печатает список созданных таблиц;
4. делает идемпотентный **бэкафилл профилей** (если есть `public.profiles`) и перечитывает кэш PostgREST.

Под капотом это тот же `cat supabase/migrations/*.sql | sudo docker exec -i supabase-db psql ...` + `\dt public.*`, но обёрнутый в проверки. Коды выхода: `0` — схема на месте (ворота C→D открыты); `3` — миграций в проекте нет (см. Вариант Б ниже); `2` — ошибка применения/пустая схема (разберись по выводу и запусти заново). **Не считай стадию C завершённой, пока скрипт не вернул `0`.**

### Бэкафилл профилей — обычно делает скрипт, но бывает нужна правка

`apply-migrations.sh` уже делает бэкафилл сам: `insert into public.profiles (id) select id from auth.users on conflict (id) do nothing`. Контекст: схема Lovable создаёт `public.profiles` **триггером на новую регистрацию** (`handle_new_user`), и для пользователей, зарегистрированных **до** применения схемы, триггер уже не сработает — без бэкафилла приложение для них падает.

Скрипт вставляет только `id`. Если у `profiles` есть **другие NOT NULL-колонки без default** (например `email`), дефолтный бэкафилл выдаст ошибку — тогда допиши `select` под свою схему и примени вручную (идемпотентно):
```bash
RSH "sudo docker exec -i supabase-db psql -U postgres -d postgres" <<'SQL'
insert into public.profiles (id, email)
select id, email from auth.users
on conflict (id) do nothing;
SQL
```

### Вариант Б: миграций нет (`apply-migrations.sh` вышел с кодом 3)

Если в проекте нет `supabase/migrations/*.sql`, скрипт останавливается (код `3`) — это сигнал снять схему из облака Lovable/Supabase. В дашборде старого проекта (Database) можно выгрузить SQL, либо через `pg_dump` по строке подключения (Project Settings → Database → Connection string):
```bash
pg_dump --schema-only "postgresql://postgres:[PASS]@db.<ref>.supabase.co:5432/postgres" > supabase/migrations/0000_init.sql
```
Положи дамп в `supabase/migrations/` (как обычную миграцию) и снова запусти `apply-migrations.sh` — дальше путь как в Варианте А (применит и проверит). Если применять разово, минуя скрипт: `cat schema.sql | RSH "sudo docker exec -i supabase-db psql -v ON_ERROR_STOP=1 -U postgres -d postgres"`.

### Перенос данных (если нужны старые данные)

```bash
pg_dump --data-only --no-owner "postgresql://...старый..." > data.sql
cat data.sql | RSH "sudo docker exec -i supabase-db psql -U postgres -d postgres"
```
Пользователей из `auth.users` переносить сложнее (хэши паролей) — для учебного проекта обычно проще, чтобы пользователи зарегистрировались заново. Предупреди пользователя.

## Шаг 4. Edge-функции

### Залить функции
```bash
set -a; . .ru-deploy/credentials.env; set +a
RU_HOST="$RU_HOST" RU_USER="$RU_USER" RU_PASS="$RU_PASS" bash "$SKILL_DIR/assets/deploy.sh" functions "$RU_DOMAIN"
```
Скрипт копирует каждую папку из `supabase/functions/` (кроме системной `main` — её трогать нельзя, это роутер edge-runtime) в `volumes/functions/` и перезапускает контейнер `functions`.

**Если `deploy.sh functions` не отработал** (споткнулся на ssh) — залей вручную тем же путём «домой → sudo cp в /opt». Для одной функции `<имя>`:
```bash
set -a; . .ru-deploy/credentials.env; set +a
export SSHPASS="$RU_PASS"   # пароль через env, не в argv
sshpass -e scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.ru-deploy/known_hosts \
  -r supabase/functions/<имя> "$RU_USER@$RU_HOST:~/ru-deploy-fn"
RSH "sudo mkdir -p /opt/supabase/docker/volumes/functions/<имя> && sudo cp -r ~/ru-deploy-fn/. /opt/supabase/docker/volumes/functions/<имя>/"
RSH "cd /opt/supabase/docker && sudo docker compose restart functions"
```
**Не удаляй** `volumes/functions/main` — без него edge-runtime не роутит функции. Если его случайно снесли — восстанавливается повторным запуском `server-setup.sh` (см. «Идемпотентность» выше).

### Прописать секреты функций (делает агент)

Секреты, которые функции читают через `Deno.env.get(...)` (нашёл на шаге 0: AI-ключ, `YOOKASSA_*` и т.п.), добавь в `/opt/supabase/docker/.env` (файл под `/opt` → пишем через `sudo tee -a`):
```bash
RSH "sudo tee -a /opt/supabase/docker/.env >/dev/null" <<'EOF'
YOOKASSA_SHOP_ID=...
YOOKASSA_SECRET_KEY=...
EOF
```

### Пробросить .env в контейнер функций — уже сделано скриптом

Чтобы edge-функции видели свои секреты (`YOOKASSA_*`, AI-ключи), сервису `functions` нужна строка `env_file: .env`. **`server-setup.sh` добавляет её сам** (через `patch-compose.py`, идемпотентно) — руками `docker-compose.yml` править не нужно. После добавления новых секретов в `.env` просто перезапусти функции:
```bash
RSH "cd /opt/supabase/docker && sudo docker compose up -d functions"
```
Проверить, что `env_file` на месте (например на сервере со старой версией скрипта):
```bash
RSH "grep -A2 '^  functions:' /opt/supabase/docker/docker-compose.yml | grep env_file"
```
Если строки нет — перезапусти `server-setup.sh` (он пропатчит compose). Авто-инжектируемые `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` в `.env` добавлять не нужно — они уже передаются.

### Публичные функции без JWT (вебхуки) — список PUBLIC_FUNCTIONS

Если функцию (обычно вебхук платёжки) зовут **без токена**, при включённой проверке JWT она вернёт `401 Missing authorization header`. **Важно: пометка `// verify_jwt = false` в коде функции на self-hosted НЕ работает** — штатный роутер `main` проверяет JWT глобально и эту строку игнорирует (в облачном Supabase так можно, здесь нет). Поэтому `server-setup.sh` ставит патч-роутер `functions-main.ts`, который пропускает функции из списка `PUBLIC_FUNCTIONS`.

Чтобы сделать функцию публичной — добавь её имя в `PUBLIC_FUNCTIONS` в серверном `.env` (через запятую, если их несколько) и перезапусти функции:
```bash
RSH "sudo sed -i 's/^PUBLIC_FUNCTIONS=.*/PUBLIC_FUNCTIONS=<имя-вебхука>/' /opt/supabase/docker/.env"
RSH "cd /opt/supabase/docker && sudo docker compose up -d functions"
```
Это безопаснее, чем глобально снимать проверку (`FUNCTIONS_VERIFY_JWT=false` открыл бы **все** функции). Точечно публичной делается только вебхук; защиту самой функции реализуй внутри неё (проверка подписи/перепроверка статуса через API платёжки — см. `payments-yookassa.md`).

### Проверка
Функция доступна по `https://<домен>/functions/v1/<имя>`. Логи: `ssh root@<IP> "cd /opt/supabase/docker && docker compose logs functions --tail 50"`.

## Полезные команды на сервере

```bash
# статус контейнеров
ssh root@<IP> "cd /opt/supabase/docker && docker compose ps"
# логи
ssh root@<IP> "cd /opt/supabase/docker && docker compose logs --tail 80"
# перезапуск всего
ssh root@<IP> "cd /opt/supabase/docker && docker compose restart"
```
