# Частые проблемы и финальная проверка

**Цель документа:** дать агенту финальный чек-лист и готовые решения типовых сбоев.

**Что делает агент:** при сбое находит здесь подходящий симптом, выполняет указанные команды, проверяет результат; в конце проходит финальный чек-лист вместе с пользователем.

> Команды `ssh root@<IP>` / `docker ...` ниже — сокращение. Заходи хелпером `RSH` (логин пользователя + `sshpass`, см. SKILL.md → «Хелпер для ssh-команд») и ставь `sudo` перед `docker`. Пример: `RSH "cd /opt/supabase/docker && sudo docker compose ps"`.

## Финальная проверка (пройди с пользователем)

- [ ] `https://<домен>` открывается, замок HTTPS зелёный.
- [ ] **Схема базы накатана** (`\dt public.*` не пустой) — иначе вход/сохранение упадут.
- [ ] Регистрация и вход работают.
- [ ] (если есть почта) «Забыли пароль?» → письмо приходит → сброс работает.
- [ ] (если есть оплата) тестовый платёж проходит, заказ становится `paid`.
- [ ] Данные сохраняются (создал что-то → перезагрузил страницу → на месте).
- [ ] (если есть AI) пользователь в курсе, что AI-часть он настраивает сам (шаг 9).
- [ ] Порт 8000 закрыт в брандмауэре Cloud.ru, открыты только 22/80/443.

## Типовые ошибки

### Не могу зайти на сервер по SSH (`Permission denied (publickey)`)
- Это значит, что на ВМ **не включён парольный вход** — образ Cloud.ru по умолчанию пускает только по ключу. Пользователь должен один раз зайти в **браузерную консоль Cloud.ru** (там логин/пароль работают) и выполнить команду включения парольного входа — см. `cloudru-setup.md` → «Включить вход по паролю».
- Если парольный вход включён, но всё равно отказ — проверь, что в команде стоит **правильный логин** пользователя (не `root`), верный IP и что задан `RU_PASS`. Утилита `sshpass` должна быть установлена локально.
- `Connection timed out` (а не «Permission denied») — закрыт порт 22 в брандмауэре Cloud.ru или неверный IP.

### fail2ban забанил агента (частые SSH-подключения → доступ пропал)
Признак: только что заходил, а теперь `Connection timed out` именно с твоего IP (с телефона/другой сети сервер пингуется). Причина: при жёстком дефолте fail2ban (`maxretry=5`) серия быстрых SSH-команд агента набирает «провалы» (таймауты/гонки) и IP агента банится.
- **Снять бан и выставить умеренный порог** — зайди через **браузерную консоль Cloud.ru** (она не по SSH, бан её не касается) и выполни:
  ```bash
  sudo fail2ban-client unban --all 2>/dev/null; printf "[sshd]\nenabled = true\nmaxretry = 20\nfindtime = 600\nbantime = 600\n" | sudo tee /etc/fail2ban/jail.local >/dev/null; sudo systemctl restart fail2ban; echo OK
  ```
  Порог станет 20 неудач/10 мин — нормальной работе агента не мешает, защита от ботов остаётся. (Если очень нужно совсем мягко для отладки — `maxretry = 100`.)
- Проверить, забанен ли твой IP: `sudo fail2ban-client status sshd` (строка `Banned IP list`).
- **Главное — убрать корневую причину:** агент должен ходить через ОДНО ssh-соединение (ControlMaster, см. SKILL.md → «Хелпер для ssh-команд») и не открывать десятки параллельных подключений. Тогда «провалов» почти не будет и при умеренном пороге.

### `sudo: a password is required` на сервере
- Редко, но бывает: у пользователя `sudo` спрашивает пароль. Тогда серверные команды оборачивай: `RSH "echo '$RU_PASS' | sudo -S <команда>"`. На стандартном образе Cloud.ru `sudo` обычно без пароля, и это не требуется.

### Сайт не открывается / нет HTTPS
- `ping <домен>` показывает не тот IP → DNS ещё не обновился или A-запись неверна.
- Порты 80/443 закрыты в брандмауэре Cloud.ru.
- Логи Caddy: `RSH "sudo docker logs caddy --tail 50"`.

### `Could not find the table 'public.<...>'` / запросы к базе падают, хотя сайт открылся
Схема базы **не накатана** — самый частый пропуск деплоя: backend подняли, фронт залили, а миграции к базе не применили. Сайт грузится, но первый же запрос к БД (вход, сохранение) падает. Проверь и почини одним шагом:
```bash
RSH "sudo docker exec -i supabase-db psql -U postgres -d postgres -c '\dt public.*'"   # пусто = схемы нет
```
Если таблиц нет — запусти шаг 3 из корня проекта (он применит и сам проверит):
```bash
set -a; . .ru-deploy/credentials.env; set +a
RU_HOST="$RU_HOST" RU_USER="$RU_USER" RU_PASS="$RU_PASS" bash "$SKILL_DIR/assets/apply-migrations.sh"
```
Скрипт применяет `supabase/migrations/*.sql`, проверяет, что таблицы появились, и бэкафиллит профили. Если миграций в проекте нет (код `3`) — сними схему из облака Lovable (`backend-supabase.md` → «Вариант Б»). Подробно — `backend-supabase.md` → «Шаг 3».

### Фронт грузится, но «не получается войти» / `401 Unauthorized` / ошибки сети
Чаще всего — **ключ или адрес фронта не совпадает с сервером**. Две разные причины, проверь обе:
1. **Ключ не тот** (`401 Unauthorized` от Kong даже с правильным доменом). `VITE_SUPABASE_PUBLISHABLE_KEY` во фронте должен в точности равняться серверному `ANON_KEY`. Сверь:
   ```bash
   RSH "sudo grep '^ANON_KEY=' /opt/supabase/docker/.env"          # серверный ключ
   grep '^VITE_SUPABASE_PUBLISHABLE_KEY=' .env                      # ключ во фронте
   ```
   Не совпали → впиши серверный `ANON_KEY` в `VITE_SUPABASE_PUBLISHABLE_KEY` и пересобери (`deploy.sh frontend`). (`deploy.sh` сверяет это сам до сборки.)
2. **Адрес не тот** — `VITE_SUPABASE_URL` указывает на старый домен (см. «Failed to fetch после смены домена»).
- В `src/integrations/supabase/client.ts` адрес/ключ могут быть **зашиты в коде** — тогда правь там и пересобирай.
- Проверь, что API живой: `curl -s https://<домен>/rest/v1/` (ожидается ответ авторизации, не таймаут).

### `Failed to fetch` после смены домена
Причина: домен поменяли не во всех местах — фронт (или Supabase Auth) стучится по старому адресу, который больше не обслуживается. Домен зашит в ТРЁХ местах, проверь каждое:
1. **Собранный фронт на сервере** содержит старый адрес. Проверь: `RSH "grep -o 'https://[a-z0-9.-]*\.sslip\.io' /var/www/app/assets/*.js | head"` — если что-то нашлось, фронт не пересобран. Поправь `VITE_SUPABASE_URL` в локальном `.env` и пересобери: `deploy.sh frontend <новый-домен>`.
2. **Серверный `.env`** — проверь, что ВСЕ четыре переменные на новом домене: `RSH "sudo grep -E '^(SITE_URL|API_EXTERNAL_URL|SUPABASE_PUBLIC_URL|ADDITIONAL_REDIRECT_URLS)=' /opt/supabase/docker/.env"`. Если хоть одна старая (частый недосмотр — `SUPABASE_PUBLIC_URL`) — запусти `RSH "bash ~/set-domain.sh <новый-домен>"`, он чинит все разом.
3. **Старый домен не отвечает по HTTPS** (TLS-ошибка в `curl` = в браузере `Failed to fetch`). После `set-domain.sh` Caddy обслуживает только новый домен — это и нужно.

Чинит всё разом скрипт смены домена (см. SKILL.md → «Смена домена»): `set-domain.sh` на сервере + пересборка фронта.

### После деплоя в браузере старая версия / «ошибка всё ещё есть», хотя фикс залит
Это **кэш**, а не невыполненный деплой. Прежде чем чинить «несуществующую» ошибку — проверь обе причины:
1. **Кэш на оболочке.** `index.html`/`sw.js` могли закэшироваться. В свежем `Caddyfile` для них уже стоит `Cache-Control: no-store`. Если сервер поднимали старой версией скрипта — обнови `/etc/caddy/Caddyfile` из `assets/Caddyfile` и перезапусти Caddy: `RSH "sudo docker restart caddy"`. Для проверки открой сайт в режиме инкогнито (там старого кэша нет).
2. **Service worker (PWA).** Если проект — PWA, старый service worker отдаёт прежнюю сборку из своего кэша. Признак: в инкогнито свежее, в обычном окне — старое. Лечение — следующий пункт.

### PWA: 404 на ссылке из письма (`/auth/v1/verify`) или залипает старая сборка
Если проект — PWA (есть `vite-plugin-pwa`, `sw.js`, `registerSW.js`), его service worker по умолчанию перехватывает **все** переходы, включая `/auth/v1/*`, и отдаёт SPA вместо ответа backend. Симптом: ссылка подтверждения email открывает React-страницу `404` вместо подтверждения.
- **Решение (правка в проекте, делает агент с согласия пользователя):** в `vite.config.ts` у `VitePWA` исключи backend-пути из перехвата service worker:
  ```ts
  // VitePWA({ workbox: { ... navigateFallbackDenylist: [...] } })
  navigateFallbackDenylist: [/^\/auth\//, /^\/rest\//, /^\/functions\//, /^\/storage\//, /^\/realtime\//],
  ```
  После правки — пересобрать и залить фронт (`deploy.sh frontend`). Если PWA в проекте нет — пункт не нужен.

### Edge-функция возвращает 500 / "configuration error"
- Не добавлен секрет в `/opt/supabase/docker/.env`, или у сервиса `functions` нет `env_file: .env` (свежий `server-setup.sh` добавляет его сам через `patch-compose.py`; на старом сервере проверь: `RSH "grep -A2 '^  functions:' /opt/supabase/docker/docker-compose.yml | grep env_file"`).
- После правки `.env`: `docker compose up -d functions`.
- Логи: `docker compose logs functions --tail 50`.

### Edge-функция/вебхук отдаёт `401 Missing authorization header`, хотя должна быть публичной
Так бывает с вебхуком YooKassa: его зовут **без** токена, а проверка JWT включена. **Пометка `// verify_jwt = false` в коде функции на self-hosted НЕ работает** — штатный роутер `main` проверяет JWT глобально. Правильно — добавить функцию в список публичных:
1. Допиши имя функции в `PUBLIC_FUNCTIONS` (через запятую) в серверном `.env`:
   ```bash
   RSH "sudo sed -i 's/^PUBLIC_FUNCTIONS=.*/PUBLIC_FUNCTIONS=<имя-вебхука>/' /opt/supabase/docker/.env"
   ```
2. Перезапусти функции: `RSH "cd /opt/supabase/docker && sudo docker compose up -d functions"`.
Это читает патч-роутер `functions-main.ts`, который ставит `server-setup.sh`. Если на сервере стоит старый стоковый роутер (нет строки `PUBLIC_FUNCTIONS-aware` в `volumes/functions/main/index.ts`) — перезапусти `server-setup.sh`, он поставит патч. **Не** снимай проверку глобально (`FUNCTIONS_VERIFY_JWT=false`) — это откроет все функции.

### Письма не приходят / регистрация падает на отправке письма
- **`SMTP_HOST` = заглушка** (`supabase-mail` и т.п.). Проверь: `RSH "sudo grep '^SMTP_HOST=' /opt/supabase/docker/.env"`. Если не реальный хост — настрой почту по `email-smtp.md`, либо на тестовом этапе временно: `EMAIL_AUTOCONFIRM=true bash ~/server-setup.sh <домен>` (потом верни `false`).
- **`535 invalid smtp auth key`** (Selectel) — неверный логин/API-key, не DNS. Детальный разбор и все типовые ошибки SMTP — в `email-smtp.md` → «Если SMTP не работает».
- Письмо ушло, но не пришло → SPF/DKIM/DMARC не настроены → спам.

### Сборка фронта: `npm ci` падает (lock-файл рассинхронен)
`npm ci` строго требует, чтобы `package-lock.json` совпадал с `package.json` — у экспортов из Lovable они часто расходятся. `deploy.sh` это переживает (фолбэк `npm install --package-lock=false` — собирает, не трогая lock пользователя), поэтому деплою ничего не мешает.
- **Разовое предупреждение пользователю:** это технический долг — каждая чистая сборка идёт через фолбэк. Чтобы убрать навсегда, нужно синхронизировать lock-файл: `npm install` (без флагов, обновит `package-lock.json`), затем закоммитить изменённый `package-lock.json`. **Делай это только с согласия пользователя** — команда меняет файл в его репозитории.
- Прочие предупреждения Vite при сборке (например `@import must precede all other statements` для шрифта в CSS) обычно **не блокируют** сборку и не ломают сайт — не расширяй правку из-за них без необходимости. Если пользователь просит навести порядок — подними `@import` шрифта в начало CSS-файла (до Tailwind-директив).

### Регистрация падает: `Error sending confirmation email`
Это **не сетевая ошибка** — фронт и API уже связаны, регистрация дошла до отправки письма, но SMTP не настроен (или `SMTP_HOST` указывает на несуществующий сервис вроде `supabase-mail`). Решения:
- Настроить настоящий SMTP (Selectel и т.п.) — стадия E, `email-smtp.md`.
- На тестовом этапе, до почты — временно отключить подтверждение: `EMAIL_AUTOCONFIRM=true bash ~/server-setup.sh <домен>` (в боевом режиме верни `false`).
Проверь текущий SMTP: `RSH "sudo grep -E '^(SMTP_HOST|ENABLE_EMAIL_AUTOCONFIRM)=' /opt/supabase/docker/.env"`.

### Платёж не помечается оплаченным
- В кабинете YooKassa не зарегистрирован URL вебхука, или указан старый домен.
- Вебхук недоступен снаружи: проверь `curl -i https://<домен>/functions/v1/<webhook>` (должен отвечать, не таймаутить).
- Логи функции: `docker compose logs functions --tail 50`.

### Не хватает памяти (контейнеры в restarting)
1. Проверь: `RSH "free -h && cd /opt/supabase/docker && sudo docker compose ps"`.
2. swap уже включён скриптом, а тяжёлые сервисы (`supavisor`, `realtime`, `analytics`, `vector`) `server-setup.sh` **и так не поднимает** — стек уже облегчён. Если памяти всё равно мало, проверь, что не запустились лишние: `RSH "cd /opt/supabase/docker && sudo docker compose ps --services --filter status=running"` — там не должно быть `supavisor`/`realtime`. Если есть — останови: `RSH "cd /opt/supabase/docker && sudo docker compose stop supavisor realtime"`.
3. Крайний вариант — взять виртуалку с большим объёмом RAM.

### Кончается место на диске (30 ГБ)
1. Посмотри, что занимает: `RSH "bash ~/server-status.sh"` (раздел «Использование места»). Образы Supabase ~9 ГБ — это норма, не трогай.
2. Безопасная чистка мусора (dangling-образы, build cache, раздувшиеся логи, apt-кэш — данные не трогаются): `RSH "bash ~/server-status.sh --clean"`.
3. Если логи раздулись (старый сервер без лимита) — включи ротацию логов Docker:
   ```bash
   RSH "echo '{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"}}' | sudo tee /etc/docker/daemon.json && sudo systemctl restart docker"
   ```
   (новые версии `server-setup.sh` ставят это сами при установке).
4. **Не делай** `docker system prune -a` и не удаляй volumes — снесёшь рабочие образы и БАЗУ ДАННЫХ.

### Команды для диагностики
```bash
set -a; . .ru-deploy/credentials.env; set +a
RSH "cd /opt/supabase/docker && sudo docker compose ps"          # статус
RSH "cd /opt/supabase/docker && sudo docker compose logs --tail 80"
RSH "free -h"                                                    # память
RSH "sudo docker logs caddy --tail 50"                          # HTTPS
```
