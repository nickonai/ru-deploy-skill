# Почта (SMTP) — сброс пароля и подтверждение email

**Цель документа:** включить отправку писем (сброс пароля, подтверждение email) через российский SMTP — стадия E. Нужен, только если в проекте есть `resetPasswordForEmail` или подтверждение email при регистрации.

**Что делает агент:**
1. Ведёт пользователя по настройке Selectel: создать ресурс, подтвердить домен (TXT в DNS), добавить SPF/DKIM/DMARC, взять числовой логин + API-key.
2. Прописывает `SMTP_*` в `/opt/supabase/docker/.env` (порт 1126, STARTTLS), пароль берёт из `.ru-deploy/credentials.env` (не из чата), ставит `ENABLE_EMAIL_AUTOCONFIRM=false`, пересоздаёт контейнер `auth`.
3. Если API-key был засвечен (скриншот/чат) — советует перевыпустить его в Selectel.
4. Проверяет: регистрация/«Забыли пароль?» → письмо приходит. При ошибке `535` — проблема в логине/ключе (см. «типовые ошибки»).

> **Команды `ssh root@<IP>`** здесь — сокращение. На деле используй хелпер `RSH` (логин пользователя + `sshpass`, см. SKILL.md → «Доступы к серверу»), а запись в `/opt`/`/var/www` и `docker` делай через `sudo`. См. тот же блок в `backend-supabase.md`.

## Почему это вообще нужно

В Lovable письма отправлялись их инфраструктурой. На своём сервере Supabase (GoTrue) — это **только SMTP-клиент**: сам письма не доставляет, а подключается к внешнему почтовому сервису. Поэтому нужен SMTP-провайдер.

## Какой провайдер выбрать (РФ)

| Провайдер | Чем хорош |
|---|---|
| **Selectel — почтовый сервис** ⭐ рекомендую | **первые 1000 писем в месяц бесплатно** (дальше платно по числу писем). SMTP-хост `smtp.mail.selcloud.ru`. Полностью в РФ, проверен на проекте dressbook. Для учебного проекта 1000 писем/мес со сбросами пароля хватает с запасом |
| **Yandex 360 для бизнеса** | альтернатива: SMTP `smtp.yandex.ru:465`, отправка с `noreply@твойдомен`. Нужен домен, подключённый к Yandex 360 |
| **Unisender Go / Mailopost / Sendsay** | российские transactional-сервисы, статистика и доставляемость — на вырост |
| Свой почтовый сервер | ❌ не надо: письма попадут в спам |

Зарубежные (SendGrid, Postmark, Resend) для РФ-проекта ненадёжны.

### Про Selectel (рекомендованный путь)

- **Бесплатно:** первые **1000 писем/месяц**. Платишь только за отправленные сверх лимита (включая неуспешные).
- **Скорость:** до 400 писем за 5 минут.
- **Лимиты:** 1 почтовый ресурс на проект, до 3 доменов на ресурс (расширяется через тикет).

**Порядок настройки в Selectel (делает пользователь):**
1. Панель Selectel → **Продукты → Почтовый сервис** → создать почтовый ресурс.
2. Добавить свой домен в ресурс. Selectel даст **TXT-запись для подтверждения владения доменом** — её пользователь добавляет в DNS (в REG.RU: тип `TXT`, host `@` или пустой = корень домена, значение — строка от Selectel).
3. Дождаться, пока проверка домена пройдёт (TXT зарезолвится).
4. Selectel также даст значения для **SPF/DKIM/DMARC** — добавить их в DNS (иначе письма в спам).
5. Взять **SMTP-логин и пароль (API-key)**: ресурс → вкладка **«Информация» (Information)**. Логин — **числовой** (например `9572`), это нормально, а не ошибка. Пароль (API-key) — техническая строка, **не** пароль от аккаунта Selectel.

**Параметры подключения (по докам Selectel):**
- Хост: `smtp.mail.selcloud.ru`
- Порт **`1126`** — STARTTLS. **Используй ИМЕННО его.** Метод авторизации `LOGIN`.
- Порт `1127` (TLS/SSL) — **не используй**: с GoTrue на нём подключение часто виснет до таймаута (`504 request_timeout` при регистрации). На скриншоте Selectel 1127 выглядит «более защищённым», но рабочий для нас — 1126.
- **Порт 25 заблокирован** Selectel (анти-спам) — не использовать.
- Логин/пароль — из вкладки «Информация» ресурса (числовой логин + API-key).

> ⚠️ **Безопасность и точность ключа.** API-key — это секрет.
> - **Не считывай ключ со скриншота** и не проси прислать картинкой. В ключе легко перепутать похожие символы (`I`/`l`/`1`, `O`/`0`) — это даёт ложную ошибку `535 invalid smtp auth key`, хотя ключ «правильный». Проси прислать ключ **текстом** и клади его в `.ru-deploy/credentials.env` как `SELECTEL_SMTP_PASS=...`.
> - Если ключ всё же был прислан скриншотом/в чате — **посоветуй перевыпустить** его в Selectel и используй новый. Сам ключ нигде не печатай и не коммить.

## Что делает пользователь

1. Заводит почтовый ресурс Selectel, подтверждает домен (TXT), добавляет SPF/DKIM/DMARC в DNS (см. выше).
2. Берёт из вкладки «Информация» ресурса: **числовой логин** и **API-key (пароль)**.
3. Присылает тебе: логин, пароль, и адрес отправителя `noreply@<домен>`. (Host/порт у Selectel известны — `smtp.mail.selcloud.ru:1126`.)

## Что делаешь ты (агент)

Пропиши `SMTP_*` в `/opt/supabase/docker/.env` (self-host сам пробросит их в GoTrue). В свежем `.env` Supabase эти ключи (`SMTP_HOST`, `SMTP_PORT` и т.д.) **уже есть** с демо-значениями — их надо **заменить**, а не дописать в конец (иначе в файле окажется две строки `SMTP_HOST=`, и GoTrue возьмёт первую). **Не вставляй пароль в чат** — бери его из `.ru-deploy/credentials.env` (строкой `SELECTEL_SMTP_PASS=...`). Пример для **Selectel** (порт 1126 = STARTTLS), безопасный к повторному запуску — заменяет строку, если есть, иначе добавляет:
```bash
set -a; . .ru-deploy/credentials.env; set +a   # тут лежит SELECTEL_SMTP_PASS и SMTP-логин
RSH "sudo python3 - <<'PY'
import re
fn='/opt/supabase/docker/.env'
vals={
 'SMTP_ADMIN_EMAIL':'noreply@<домен>',
 'SMTP_HOST':'smtp.mail.selcloud.ru',
 'SMTP_PORT':'1126',
 'SMTP_USER':'<числовой-логин-ресурса>',
 'SMTP_PASS':'$SELECTEL_SMTP_PASS',
 'SMTP_SENDER_NAME':'<Название проекта>',
}
lines=open(fn).read().splitlines()
seen=set()
out=[]
for l in lines:
    k=l.split('=',1)[0] if '=' in l else None
    if k in vals:
        out.append(k+'='+vals[k]); seen.add(k)
    else:
        out.append(l)
for k,v in vals.items():
    if k not in seen: out.append(k+'='+v)
open(fn,'w').write('\n'.join(out)+'\n')
print('SMTP прописан')
PY"
```
(Для Yandex 360 — `SMTP_HOST=smtp.yandex.ru`, `SMTP_PORT=465`, логин/пароль = адрес и «пароль приложения».)
Затем — отключи авто-подтверждение (если включалось на время установки) и перезапусти авторизацию **с пересозданием** (иначе новые `SMTP_*` не подхватятся):
```bash
RSH "cd /opt/supabase/docker && sudo sed -i 's/^ENABLE_EMAIL_AUTOCONFIRM=.*/ENABLE_EMAIL_AUTOCONFIRM=false/' .env && sudo docker compose up -d --force-recreate auth"
```

### Если SMTP не работает — типовые ошибки

- **`535 5.7.0 invalid smtp auth key`** — почти всегда **логин/ключ**, а **не** DNS и не сеть (раз ошибка дошла — соединение есть). Чаще всего это **опечатка/перепутанный символ** в ключе, считанном со скриншота (`I`↔`l`, `O`↔`0`). Перепроверь ключ как текст из `.ru-deploy/credentials.env`; убедись, что логин — числовой из вкладки «Информация». Если ключ был засвечен и перевыпущен — возьми новый. Метод авторизации — `LOGIN`.
- **Зависание/timeout при подключении (`504 request_timeout`)** — почти всегда порт `1127` вместо `1126`. Поставь `SMTP_PORT=1126` (STARTTLS) и пересоздай `auth`. Порт `25` у Selectel заблокирован.
- **Письмо «отправлено», но не пришло** — не настроены SPF/DKIM/DMARC → спам. Проверь DNS и папку «Спам». Если SPF стоит как `?all` (нейтрально) — после того как письма пошли только через Selectel, смени на `~all` (softfail) для лучшей доставляемости.
- Смотри лог: `RSH "cd /opt/supabase/docker && sudo docker compose logs auth --tail 50"`.

## DNS-записи (делает пользователь у регистратора домена)

Все добавляются как **TXT-записи** в DNS домена (в REG.RU: тип `TXT`, host `@` или пустой = корень). Selectel даёт значения в карточке ресурса/домена:

- **Подтверждение домена** — TXT с проверочной строкой (без неё ресурс не активируется).
- **SPF** — разрешает Selectel слать письма от твоего домена.
- **DKIM** — подпись писем.
- **DMARC** — политика (влияет на доставляемость, не на авторизацию SMTP).

Подтверждение домена обязательно сразу; SPF/DKIM/DMARC обязательны, чтобы письма не падали в спам. Пользователь добавляет их в REG.RU, агент ждёт, пока зарезолвятся (`dig TXT <домен>`).

> ⚠️ **Грабли REG.RU: не дублируй домен в поле «host/субдомен».** REG.RU сам дописывает зону. В поле имени записи вводи **только** короткую часть: `@` (или пусто) для корня, `_dmarc` для DMARC, `selcloud._domainkey` (или что выдал Selectel) для DKIM — **без** `.<твойдомен>.ru`. Если ввести полный домен, получится `_dmarc.твойдомен.ru.твойдомен.ru`, и Selectel запись не увидит. Проверка на удвоение: `dig TXT _dmarc.<домен>` должно отвечать; `dig TXT _dmarc.<домен>.<домен>` — нет.

## Русские шаблоны писем (по желанию)

Готовые шаблоны лежат в `assets/email-templates/` (`recovery.html`, `confirmation.html`, `email_change.html`, `invite.html`). Сервис `auth` уже умеет их читать — `server-setup.sh` пробросил переменные `GOTRUE_MAILER_SUBJECTS_*`/`GOTRUE_MAILER_TEMPLATES_*` в compose (через `patch-compose.py`), а сами значения берутся из `.env`. Поэтому подключить шаблоны = разложить HTML + задать переменные в `.env` + пересоздать `auth`. YAML править не нужно.

1. Залей шаблоны в раздаваемую папку (доступны по HTTPS): заливаем в `~`, потом `sudo`-копируем в `/var/www`:
   ```bash
   set -a; . .ru-deploy/credentials.env; set +a
   export SSHPASS="$RU_PASS"   # пароль через env, не в argv
   sshpass -e scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.ru-deploy/known_hosts "$SKILL_DIR"/assets/email-templates/*.html "$RU_USER@$RU_HOST:~/"
   RSH "sudo mkdir -p /var/www/app/email-templates && sudo cp ~/recovery.html ~/confirmation.html ~/email_change.html ~/invite.html /var/www/app/email-templates/"
   ```
2. Пропиши темы и адреса шаблонов в серверный `.env` (compose уже ссылается на эти переменные):
   ```bash
   RSH "sudo tee -a /opt/supabase/docker/.env >/dev/null" <<'EOF'
   MAILER_SUBJECTS_CONFIRMATION=Подтвердите email
   MAILER_SUBJECTS_RECOVERY=Сброс пароля
   MAILER_SUBJECTS_EMAIL_CHANGE=Подтвердите новый email
   MAILER_SUBJECTS_INVITE=Приглашение
   MAILER_TEMPLATES_CONFIRMATION=https://<домен>/email-templates/confirmation.html
   MAILER_TEMPLATES_RECOVERY=https://<домен>/email-templates/recovery.html
   MAILER_TEMPLATES_EMAIL_CHANGE=https://<домен>/email-templates/email_change.html
   MAILER_TEMPLATES_INVITE=https://<домен>/email-templates/invite.html
   EOF
   ```
   (если переменная `MAILER_*` уже есть в `.env` — замени её значение через `sed`, а не дублируй строку.)
3. Пересоздай `auth`, чтобы он перечитал `.env`:
   ```bash
   RSH "cd /opt/supabase/docker && sudo docker compose up -d --force-recreate auth"
   ```

## Проверка

На сайте «Забыли пароль?» → ввести email → письмо приходит → ссылка ведёт на страницу нового пароля. Если письма нет — смотри «Если SMTP не работает — типовые ошибки» выше.
