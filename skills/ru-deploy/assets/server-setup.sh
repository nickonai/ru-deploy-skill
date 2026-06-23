#!/usr/bin/env bash
#
# ru-deploy: установка backend на сервере Cloud.ru одним скриптом.
# Поднимает self-hosted Supabase (Docker) + Caddy (HTTPS) для проекта с Lovable.
#
# Запуск НА СЕРВЕРЕ:
#   bash server-setup.sh <домен>
# Пример:
#   bash server-setup.sh myapp.ru
#
# Работает из-под обычного пользователя Cloud.ru (например `admin`) — все
# системные действия идут через sudo. Пользователь на Cloud.ru обычно имеет
# passwordless sudo, поэтому ssh-команда не зависнет на запросе пароля.
#
# Перед запуском залей рядом gen-keys.py, Caddyfile, patch-compose.py и
# functions-main.ts (см. SKILL.md, шаг 2). DNS домена уже должен указывать на
# этот сервер — иначе Caddy не выдаст HTTPS.

set -euo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
	echo "Ошибка: укажи домен. Пример: bash server-setup.sh myapp.ru"
	exit 1
fi

# sudo, если мы не root (на Cloud.ru дефолтный пользователь — не root, но с sudo).
if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
else
	SUDO="sudo"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SUPABASE_DIR="/opt/supabase/docker"
ENV_FILE="$SUPABASE_DIR/.env"

# Обёртки: docker и запись в /opt требуют root → гоняем через sudo.
dock() { $SUDO docker "$@"; }
dcomp() { $SUDO docker compose "$@"; }

echo "=========================================="
echo "  ru-deploy: установка сервера для $DOMAIN"
echo "=========================================="

# --- хелпер: задать/заменить переменную в .env (файл под /opt → sudo) ---
# .env содержит все секреты (POSTGRES_PASSWORD, JWT_SECRET, SERVICE_ROLE_KEY) —
# umask 077 гарантирует, что даже при создании файл будет доступен только владельцу.
set_env() {
	$SUDO python3 - "$1" "$2" "$ENV_FILE" <<'PY'
import sys, os
os.umask(0o077)  # новые файлы — 600, секреты не утекут через права
key, val, fn = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(fn).read().splitlines()
except FileNotFoundError:
    lines = []
out, done = [], False
for l in lines:
    if l.startswith(key + "="):
        out.append(f"{key}={val}"); done = True
    else:
        out.append(l)
if not done:
    out.append(f"{key}={val}")
open(fn, "w").write("\n".join(out) + "\n")
PY
	# на случай, если файл уже существовал с широкими правами — ужимаем явно
	$SUDO chmod 600 "$ENV_FILE" 2>/dev/null || true
}

# ---- fail2ban: умеренный порог ----
# Корневую причину самобана агента решает ControlMaster на стороне клиента (одно
# ssh-соединение на сессию, см. SKILL.md → «Хелпер для ssh-команд»), поэтому здесь
# порог нужен лишь УМЕРЕННЫЙ, а не «нараспашку»: 20 неудач за 10 минут. Это переживает
# редкие сбои/таймауты агента, но реальный перебор паролей ботами отсекает быстро.
# Очень мягкий режим (для отладки) — только по явному opt-in RU_RELAX_FAIL2BAN=1.
if command -v fail2ban-client >/dev/null 2>&1; then
	if [ "${RU_RELAX_FAIL2BAN:-0}" = "1" ]; then
		printf '[sshd]\nenabled = true\nmaxretry = 100\nfindtime = 3600\nbantime = 600\n' | $SUDO tee /etc/fail2ban/jail.local >/dev/null
		echo "  fail2ban: ОЧЕНЬ мягкий порог (100/час) — RU_RELAX_FAIL2BAN=1."
	else
		printf '[sshd]\nenabled = true\nmaxretry = 20\nfindtime = 600\nbantime = 600\n' | $SUDO tee /etc/fail2ban/jail.local >/dev/null
		echo "  fail2ban: умеренный порог (20 неудач/10 мин)."
	fi
	$SUDO systemctl restart fail2ban 2>/dev/null || true
fi

# ---- [1/7] swap (страховка от нехватки памяти на 4 ГБ) ----
echo ""
echo "[1/7] Настраиваю swap..."
if ! $SUDO swapon --show | grep -q '/swapfile'; then
	$SUDO fallocate -l 4G /swapfile || $SUDO dd if=/dev/zero of=/swapfile bs=1M count=4096
	$SUDO chmod 600 /swapfile
	$SUDO mkswap /swapfile
	$SUDO swapon /swapfile
	$SUDO grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null
	echo "  swap 4 ГБ включён."
else
	echo "  swap уже есть."
fi

# ---- [2/7] системные пакеты ----
echo ""
echo "[2/7] Ставлю системные пакеты..."
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -y
$SUDO apt-get install -y ca-certificates curl gnupg git python3

# ---- [3/7] Docker ----
echo ""
echo "[3/7] Ставлю Docker..."
if ! command -v docker >/dev/null 2>&1; then
	$SUDO install -m 0755 -d /etc/apt/keyrings
	$SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
	$SUDO chmod a+r /etc/apt/keyrings/docker.asc
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
	$SUDO apt-get update -y
	$SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	$SUDO systemctl enable docker && $SUDO systemctl start docker
	echo "  Docker установлен."
else
	echo "  Docker уже установлен."
fi

# Лимит на логи контейнеров: по умолчанию json-логи Docker растут БЕЗ предела и
# со временем забивают диск на маленькой free-tier ВМ. Ставим ротацию: максимум
# 3 файла по 10 МБ на контейнер. Делается один раз, до запуска контейнеров.
if [ ! -f /etc/docker/daemon.json ]; then
	$SUDO mkdir -p /etc/docker
	printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' | $SUDO tee /etc/docker/daemon.json >/dev/null
	$SUDO systemctl restart docker
	echo "  Лимит логов Docker включён (10m x3 на контейнер)."
fi

# ---- [4/7] Клонирую Supabase ----
echo ""
echo "[4/7] Скачиваю Supabase..."
# Нужна только папка docker/ из огромного монорепо — берём sparse checkout
# (скачивает лишь нужное, а не сотни МБ всего репозитория). Если sparse не
# поддержан старым git — фолбэк на обычный clone.
if [ ! -d "/opt/supabase/docker" ]; then
	$SUDO rm -rf /opt/supabase
	if ! $SUDO git clone --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase.git /opt/supabase 2>/dev/null \
		|| ! ( cd /opt/supabase && $SUDO git sparse-checkout set docker ); then
		echo "  sparse checkout не вышел — обычный clone..."
		$SUDO rm -rf /opt/supabase
		$SUDO git clone --depth 1 https://github.com/supabase/supabase.git /opt/supabase
	fi
fi
cd "$SUPABASE_DIR"
[ -f "$ENV_FILE" ] || $SUDO cp .env.example .env
$SUDO chmod 600 "$ENV_FILE"   # .env с секретами — только для владельца

# ---- Проверка целостности (идемпотентность) ----
# Если установку прерывали или папку docker/ «реставрировали» руками, Docker мог
# создать ДИРЕКТОРИИ на месте служебных файлов (kong.yml, *.sql) — тогда Kong/Postgres
# падают с "not a directory". Чиним ДО генерации ключей: перевыкачиваем эталонную
# docker/ из шаблона, сохранив данные базы (volumes/db/data). Ключи в .env пропишутся
# ниже в [5] поверх — поэтому порядок важен. Повторный запуск скрипта безопасен.
# Все служебные bind-mount ФАЙЛЫ, которые Docker может ошибочно создать как каталоги,
# если при старте контейнера файла не было (частично прерванная установка). Если хоть
# один стал каталогом — восстанавливаем папку docker/ из шаблона.
SVC_FILES="volumes/api/kong.yml volumes/api/kong-entrypoint.sh volumes/pooler/pooler.exs volumes/logs/vector.yml volumes/db/realtime.sql volumes/db/webhooks.sql volumes/db/roles.sql volumes/db/jwt.sql volumes/db/_supabase.sql volumes/db/logs.sql volumes/db/pooler.sql"
need_restore=0
[ -f "$SUPABASE_DIR/docker-compose.yml" ] || need_restore=1
for f in $SVC_FILES; do
	[ -d "$SUPABASE_DIR/$f" ] && need_restore=1   # каталог на месте файла = повреждение
done
if [ "$need_restore" = "1" ]; then
	echo "  ⚠ Повреждённые служебные файлы Supabase (каталог вместо файла) — восстанавливаю docker/ из шаблона (данные БД сохраняю)."
	TMP="/tmp/supabase-fresh-$$"
	$SUDO rm -rf "$TMP"
	$SUDO git clone --depth 1 --filter=blob:none --sparse https://github.com/supabase/supabase.git "$TMP" >/dev/null 2>&1 \
		&& ( cd "$TMP" && $SUDO git sparse-checkout set docker >/dev/null 2>&1 ) \
		|| $SUDO git clone --depth 1 https://github.com/supabase/supabase.git "$TMP" >/dev/null 2>&1
	# Сносим именно кривые узлы-каталоги, затем накатываем эталон поверх
	for f in $SVC_FILES; do
		[ -d "$SUPABASE_DIR/$f" ] && $SUDO rm -rf "$SUPABASE_DIR/$f"
	done
	# Накатываем эталонные docker-файлы поверх; volumes/db/data НЕ трогаем (данные БД)
	$SUDO cp -a "$TMP/docker/." "$SUPABASE_DIR/" 2>/dev/null
	$SUDO rm -rf "$TMP"
	echo "  восстановлено."
fi

# ---- [5/7] Генерирую секреты и прописываю домен ----
echo ""
echo "[5/7] Генерирую ключи и настраиваю .env..."

# КРИТИЧНО для идемпотентности: секреты генерируем при ПЕРВОЙ установке и сохраняем
# при повторной. При повторном запуске база (volumes/db/data) уже инициализирована со
# старым POSTGRES_PASSWORD/JWT_SECRET — если сгенерировать новые, сервисы пойдут с новым
# паролем, а Postgres хранит старый → "password authentication failed", контейнеры падают.
# НО: свежий .env.example содержит ДЕМО-плейсхолдеры (публично известные!) — их
# обязательно заменить на сгенерированные, иначе JWT_SECRET будет публичным.
get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }
# демо-значения из .env.example, которые НЕЛЬЗЯ оставлять (считаем «пусто»)
is_demo() {
	case "$1" in
		""|*your-super-secret*|*your-tenant*|*supabase-demo*|*this_password_is_insecure*) return 0 ;;
		# демо ANON/SERVICE ключи Supabase имеют iss "supabase-demo" (проверяем декодом payload)
		eyJ*) python3 -c "import sys,base64,json;p=sys.argv[1].split('.')[1];p+='='*(-len(p)%4);d=json.loads(base64.urlsafe_b64decode(p));sys.exit(0 if d.get('iss')=='supabase-demo' else 1)" "$1" 2>/dev/null && return 0 || return 1 ;;
		*) return 1 ;;
	esac
}
# задать ключ, только если он отсутствует/пустой/демо (настоящие секреты сохраняем)
set_env_once() { is_demo "$(get_env "$1")" && set_env "$1" "$2" || true; }

set_env_once POSTGRES_PASSWORD "$(openssl rand -hex 24)"
set_env_once JWT_SECRET "$(openssl rand -hex 32)"
# JWT_SECRET теперь точно есть в .env — берём его и генерируем ключи из него (если их нет)
JWT_SECRET="$(get_env JWT_SECRET)"
set_env_once ANON_KEY "$(python3 "$HERE/gen-keys.py" "$JWT_SECRET" anon)"
set_env_once SERVICE_ROLE_KEY "$(python3 "$HERE/gen-keys.py" "$JWT_SECRET" service_role)"
ANON_KEY="$(get_env ANON_KEY)"   # для финального вывода
# В новых .env Supabase есть ПОЛЯ нового формата ключей (sb_publishable_.../sb_secret_...).
# Их НЕЛЬЗЯ заполнять legacy-JWT (ANON_KEY/SERVICE_ROLE_KEY) — Kong увидит дубли и упадёт.
# Оставляем их пустыми: при пустых значениях стек использует legacy JWT-ключи (наш режим).
grep -q '^SUPABASE_PUBLISHABLE_KEY=' "$ENV_FILE" 2>/dev/null && set_env SUPABASE_PUBLISHABLE_KEY ""
grep -q '^SUPABASE_SECRET_KEY=' "$ENV_FILE" 2>/dev/null && set_env SUPABASE_SECRET_KEY ""
set_env DASHBOARD_USERNAME "admin"
set_env_once DASHBOARD_PASSWORD "$(openssl rand -hex 16)"
set_env_once SECRET_KEY_BASE "$(openssl rand -hex 32)"
set_env_once VAULT_ENC_KEY "$(openssl rand -hex 16)"
# Домен/URL можно безопасно обновлять при каждом запуске — это не секреты.
set_env SITE_URL "https://$DOMAIN"
set_env API_EXTERNAL_URL "https://$DOMAIN"
set_env SUPABASE_PUBLIC_URL "https://$DOMAIN"
set_env ADDITIONAL_REDIRECT_URLS "https://$DOMAIN/**"
# Домен, которому GoTrue доверяет в ссылках из писем (иначе ссылки подтверждения
# могут не работать). Обновляется при каждом запуске вместе с остальными URL.
set_env MAILER_EXTERNAL_HOSTS "$DOMAIN"
# Список публичных edge-функций (через запятую), которым НЕ нужен JWT — например
# вебхук YooKassa. Патч-роутер functions-main.ts читает его (см. [6.5] ниже).
# Создаём пустым при первой установке; имена добавляет агент на шаге платежей.
grep -q '^PUBLIC_FUNCTIONS=' "$ENV_FILE" 2>/dev/null || set_env PUBLIC_FUNCTIONS ""
# Переменные кастомных писем GoTrue (русские темы/шаблоны). Пустые → GoTrue
# использует встроенные англоязычные; заполняет их шаг «Почта». Создаём пустыми,
# чтобы подстановка ${...} в docker-compose.yml не ругалась на неизвестную переменную.
for v in MAILER_SUBJECTS_INVITE MAILER_SUBJECTS_CONFIRMATION MAILER_SUBJECTS_RECOVERY \
	MAILER_SUBJECTS_EMAIL_CHANGE MAILER_TEMPLATES_INVITE MAILER_TEMPLATES_CONFIRMATION \
	MAILER_TEMPLATES_RECOVERY MAILER_TEMPLATES_EMAIL_CHANGE; do
	grep -q "^$v=" "$ENV_FILE" 2>/dev/null || set_env "$v" ""
done
# Проверка JWT для edge-функций. По умолчанию ВКЛЮЧЕНА (безопасно).
# ВАЖНО: пометка `// verify_jwt = false` в коде функции на self-hosted НЕ работает —
# штатный роутер main проверяет JWT глобально и эту строку не читает. Поэтому для
# публичных вебхуков (YooKassa и т.п.) мы ставим патч-роутер functions-main.ts
# (см. [6.5] ниже), который пропускает функции из списка PUBLIC_FUNCTIONS. Не снимай
# проверку глобально (FUNCTIONS_VERIFY_JWT=false) — это открывает ВСЕ функции.
set_env FUNCTIONS_VERIFY_JWT "${FUNCTIONS_VERIFY_JWT:-true}"
# Подтверждение email. По умолчанию ВКЛЮЧЕНО (autoconfirm=false): без подтверждения
# почты вход запрещён — это правильно для боевого режима. НО пока не настроен SMTP
# (шаг 7), письма не уходят и зарегистрироваться нельзя. Если нужно протестировать
# регистрацию до настройки почты — включи autoconfirm ОСОЗНАННО и временно:
#   EMAIL_AUTOCONFIRM=true bash server-setup.sh <домен>
# и обязательно верни false после настройки SMTP. По умолчанию — безопасный false.
case "${EMAIL_AUTOCONFIRM:-false}" in
	true|1|yes) set_env ENABLE_EMAIL_AUTOCONFIRM "true";
		echo "  ⚠ ENABLE_EMAIL_AUTOCONFIRM=true (временно, для теста — верни false после SMTP)";;
	*) set_env ENABLE_EMAIL_AUTOCONFIRM "false";;
esac

# .env обязателен — без него docker compose подставит пустые значения и сломает контейнеры
if [ ! -f "$ENV_FILE" ]; then
	echo "  ОШИБКА: нет $ENV_FILE. Прерываю — нельзя поднимать стек без .env."
	exit 1
fi

# ---- [6.0] Патч роутера функций + docker-compose.yml ----
# Делаем ДО запуска контейнеров, чтобы стартовали уже исправленные сервисы.
# (а) Патч-роутер functions-main.ts умеет пропускать публичные функции из
#     PUBLIC_FUNCTIONS мимо проверки JWT (штатный роутер так не умеет — см. выше).
#     Ставим его поверх системного volumes/functions/main/index.ts.
if [ -f "$HERE/functions-main.ts" ]; then
	$SUDO mkdir -p "$SUPABASE_DIR/volumes/functions/main"
	$SUDO cp "$HERE/functions-main.ts" "$SUPABASE_DIR/volumes/functions/main/index.ts"
	echo "  Патч-роутер функций установлен (PUBLIC_FUNCTIONS-aware)."
fi
# (б) Патч docker-compose.yml: env_file для functions (иначе функции не видят
#     секреты из .env) + переменные кастомных писем для auth. Идемпотентно.
if [ -f "$HERE/patch-compose.py" ]; then
	$SUDO python3 "$HERE/patch-compose.py" "$SUPABASE_DIR/docker-compose.yml" || \
		echo "  ⚠ не удалось пропатчить docker-compose.yml — проверь вручную (env_file для functions)."
fi

# ---- [6/7] Запускаю Supabase (только нужные сервисы) ----
echo ""
echo "[6/7] Запускаю контейнеры Supabase (первый раз — несколько минут)..."
# Поднимаем ТОЛЬКО то, что нужно простому Lovable-проекту — экономим RAM на free-tier
# и убираем целый класс ошибок. Берём реальный список сервисов из compose и ИСКЛЮЧАЕМ
# ненужные (устойчиво к разным версиям шаблона). Остаётся: db, kong, auth, rest,
# storage, imgproxy, functions, meta, studio.
# Исключаем:
#   supavisor (pooler) — пул соединений для нагрузки; у нас стабильно падал;
#   realtime          — websocket-подписки; простому проекту не нужны;
#   analytics, vector — сбор логов; прожорливы по RAM; в свежем шаблоне их часто и нет.
EXCLUDE="supavisor realtime analytics vector"
ALL_SERVICES="$($SUDO docker compose config --services 2>/dev/null)"
SERVICES=""
for s in $ALL_SERVICES; do
	skip=0
	for e in $EXCLUDE; do [ "$s" = "$e" ] && skip=1; done
	[ "$skip" = "0" ] && SERVICES="$SERVICES $s"
done
[ -n "$SERVICES" ] || SERVICES="$ALL_SERVICES"   # фолбэк: если что-то пошло не так — поднять всё
echo "  Поднимаю сервисы:$SERVICES"
dcomp pull $SERVICES 2>/dev/null || dcomp pull $SERVICES
dcomp up -d $SERVICES
echo "  Жду инициализацию (40 сек)..."
sleep 40

# ---- [7/7] Caddy (HTTPS) ----
echo ""
echo "[7/7] Поднимаю Caddy с авто-HTTPS..."
$SUDO mkdir -p /etc/caddy /var/www/app
[ -f "$HERE/Caddyfile" ] && $SUDO cp "$HERE/Caddyfile" /etc/caddy/Caddyfile
# Заглушка, чтобы сайт что-то показывал до заливки фронта
[ -f /var/www/app/index.html ] || echo "<h1>ru-deploy: сервер готов. Залей фронтенд (шаг 5).</h1>" | $SUDO tee /var/www/app/index.html >/dev/null

dock rm -f caddy >/dev/null 2>&1 || true
dock run -d --name caddy --restart unless-stopped --network host \
	-e DOMAIN="$DOMAIN" \
	-v /etc/caddy/Caddyfile:/etc/caddy/Caddyfile \
	-v /var/www/app:/var/www/app \
	-v caddy_data:/data -v caddy_config:/config \
	caddy:2

echo ""
echo "=========================================="
echo "  Готово! Backend и HTTPS подняты."
echo "=========================================="
echo ""
echo "  Адрес backend (VITE_SUPABASE_URL):   https://$DOMAIN"
echo "  Ключ для фронта (VITE_SUPABASE_PUBLISHABLE_KEY):"
echo ""
echo "    $ANON_KEY"
echo ""
echo "  Сохрани этот ключ — он нужен на шаге 5 (фронт)."
echo "  Проверка: открой https://$DOMAIN/rest/v1/ (ответ с ошибкой авторизации = всё ок)."
echo ""
echo "  ВАЖНО: в брандмауэре Cloud.ru открой только порты 22, 80, 443."
echo "  Порт 8000 (Supabase) наружу открывать НЕ нужно."
echo ""
