# Стадия C: backend (шаги 2-4)

Ворота стадии C → D (проверка схемы и подтверждение пользователя перед фронтом) остаются в `SKILL.md` и обязательны.

## Шаг 2. Backend на сервере (один скрипт)

Подробно — в `references/backend-supabase.md`. Суть: на сервере поднимается self-hosted Supabase в Docker + Caddy для HTTPS.

1. Залей на сервер установочный скрипт и его помощников (в домашнюю папку пользователя, не в `/root`). Нужны все четыре файла — без `patch-compose.py`/`functions-main.ts` функции не увидят секреты и публичные вебхуки не заработают:
   ```bash
   set -a; . .ru-deploy/credentials.env; set +a
   export SSHPASS="$RU_PASS"   # пароль через env, не в argv (см. «Хелпер для ssh-команд»)
   sshpass -e scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.ru-deploy/known_hosts \
     "$SKILL_DIR/assets/server-setup.sh" "$SKILL_DIR/assets/gen-keys.py" "$SKILL_DIR/assets/Caddyfile" \
     "$SKILL_DIR/assets/patch-compose.py" "$SKILL_DIR/assets/functions-main.ts" \
     "$RU_USER@$RU_HOST:~/"
   ```
2. Запусти установку (подставь домен пользователя):
   ```bash
   RSH "bash ~/server-setup.sh <домен>"
   ```
   (если вход по ключу, а не паролю — `RU_PASS` пуст, и `sshpass` не нужен; используй обычный `scp`/`ssh`.)
   Скрипт сам: включит swap (страховка от нехватки памяти на 4 ГБ), поставит Docker и Caddy, склонирует Supabase, **сгенерирует все ключи** (`POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`), пропишет домен, поднимет контейнеры и настроит Caddy с авто-HTTPS.
3. В конце скрипт напечатает **`ANON_KEY`** (он же `VITE_SUPABASE_PUBLISHABLE_KEY`) — сохрани, нужен на шаге 5.

Проверка: `https://<домен>/rest/v1/` отвечает (обычно ошибкой авторизации — это нормально, значит API живой и HTTPS есть).

---

## Шаг 3. Схема базы (миграции) — отдельный обязательный шаг

**Это самый пропускаемый шаг, и его пропуск ломает сайт незаметно.** Частый баг прошлых деплоев: backend подняли, фронт залили, а миграции к базе **не применили** → схема `public` пустая → сайт открывается, но падает с `Could not find the table 'public.<...>'`, как только пользователь войдёт или что-то сохранит. Поэтому миграции — **самостоятельный шаг с самопроверкой**, а не «между делом».

Запусти готовый скрипт из корня проекта — он применяет миграции по порядку, **сам проверяет**, что схема накатилась (иначе падает), и делает идемпотентный бэкафилл профилей:
```bash
set -a; . .ru-deploy/credentials.env; set +a
RU_HOST="$RU_HOST" RU_USER="$RU_USER" RU_PASS="$RU_PASS" bash "$SKILL_DIR/assets/apply-migrations.sh"
```

Что делает скрипт и как читать его выход:
- **Есть `supabase/migrations/*.sql`** → применяет их (по порядку имён, с остановкой на первой ошибке), печатает список созданных таблиц, бэкафиллит профили существующих пользователей. Код выхода `0` = схема на месте.
- **Папки миграций НЕТ** → выходит с кодом `3` и просит снять схему из облака Lovable (`pg_dump --schema-only`). **Остановись и скажи об этом пользователю** — без схемы дальше идти нельзя (см. `references/backend-supabase.md` → «Вариант Б: миграций нет»). Сними схему, положи в `supabase/migrations/` и запусти скрипт снова.
- **Ошибка применения** (код `2`) → разберись по выводу psql (часто: повтор без guard'ов, ссылка на отсутствующую роль/расширение), поправь миграцию, запусти заново.

Перенос **существующих данных** из облака Lovable (если они нужны) — отдельная процедура, см. справочник.

---

## Шаг 4. Edge-функции

См. `references/backend-supabase.md` → «Edge-функции». Кратко:

1. Залей функции и добавь их секреты на сервер (AI-ключ, `YOOKASSA_*` и т.д. — то, что нашёл на шаге 0) скриптом (доступы он берёт из окружения):
   ```bash
   set -a; . .ru-deploy/credentials.env; set +a
   RU_HOST="$RU_HOST" RU_USER="$RU_USER" RU_PASS="$RU_PASS" bash "$SKILL_DIR/assets/deploy.sh" functions "$RU_DOMAIN"
   ```
2. Контейнер функций уже видит секреты из `.env` — `server-setup.sh` добавил сервису `functions` строку `env_file` сам (через `patch-compose.py`). Вручную YAML править не нужно. После добавления новых секретов в `.env` перезапусти функции: `RSH "cd /opt/supabase/docker && sudo docker compose up -d functions"`.
3. Если функция — **публичный вебхук** (зовётся без токена, например YooKassa): пометка `// verify_jwt = false` в коде на self-hosted **не работает**; вместо этого добавь имя функции в `PUBLIC_FUNCTIONS` в серверном `.env` (см. `references/backend-supabase.md` → «Публичные функции без JWT»). Это шаг 8 (платежи) — здесь просто помни про механизм.
4. Функции доступны по `https://<домен>/functions/v1/<имя>`.
