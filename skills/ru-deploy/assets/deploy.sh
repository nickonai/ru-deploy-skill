#!/usr/bin/env bash
#
# ru-deploy: заливка проекта с компьютера пользователя на сервер Cloud.ru.
# Запускать ИЗ КОРНЯ проекта (где package.json).
#
#   bash deploy.sh frontend  [домен]   # собрать фронт и залить
#   bash deploy.sh functions [домен]   # залить edge-функции и перезапустить
#   bash deploy.sh all       [домен]   # и то, и другое
#
# Доступ к серверу берётся из окружения (их выставляет агент из файла доступов,
# см. SKILL.md → «Доступы к серверу»):
#   RU_HOST   — IP виртуалки (обязательно)
#   RU_USER   — логин на сервере (по умолчанию: тот, что задал пользователь при
#               создании ВМ, например `admin`)
#   RU_PASS   — пароль (если вход по паролю; требует утилиту sshpass)
# Если RU_PASS пуст — используется вход по ssh-ключу (RU_PASS не нужен).
#
# Пример запуска агентом:
#   RU_HOST=176.123.160.180 RU_USER=admin RU_PASS='...' bash deploy.sh all myapp.ru

set -euo pipefail

MODE="${1:-}"
DOMAIN="${2:-}"

RU_HOST="${RU_HOST:-}"
RU_USER="${RU_USER:-admin}"
RU_PASS="${RU_PASS:-}"

if [ -z "$MODE" ] || [ -z "$RU_HOST" ]; then
	echo "Использование: RU_HOST=<IP> RU_USER=<логин> [RU_PASS=<пароль>] bash deploy.sh <frontend|functions|all> [домен]"
	exit 1
fi
[ -f package.json ] || { echo "Запусти из корня проекта (нет package.json)"; exit 1; }

SERVER="$RU_USER@$RU_HOST"
FUNCS_REMOTE="/opt/supabase/docker/volumes/functions"
WEB_REMOTE="/var/www/app"

# Закрепляем ключ хоста (TOFU): при первом подключении доверяем и запоминаем
# ключ сервера в .ru-deploy/known_hosts, дальше сверяемся с ним. Это защищает
# от подмены сервера (MITM), при этом не требует от новичка ручной проверки.
KNOWN_HOSTS="${RU_KNOWN_HOSTS:-.ru-deploy/known_hosts}"
mkdir -p "$(dirname "$KNOWN_HOSTS")" 2>/dev/null || true
[ -f "$KNOWN_HOSTS" ] || : > "$KNOWN_HOSTS"
# accept-new: принять ключ только если его ещё нет; если ключ изменился — отказать (возможный MITM).
# ControlMaster: все ssh/scp/rsync этого запуска переиСПОЛЬЗУЮТ одно соединение (одна
# аутентификация), а не открывают по новой на каждый файл. Это и быстрее, и убирает
# корневую причину самобана fail2ban — без шквала авторизаций бан не срабатывает.
CM_DIR="${RU_CM_DIR:-.ru-deploy/cm}"
mkdir -p "$CM_DIR" 2>/dev/null || true
HK_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ControlMaster=auto -o ControlPath=$CM_DIR/%r@%h:%p -o ControlPersist=120"

# Если задан пароль — гоняем ssh/scp/rsync через sshpass. Иначе обычный ключевой вход.
# PreferredAuthentications не пиним: если у пользователя есть ssh-ключ — он сработает.
# ВАЖНО: пароль передаём через переменную окружения (sshpass -e), а НЕ через `-p <пароль>`,
# иначе он виден в `ps` всем пользователям машины (argv процесса публичен).
if [ -n "$RU_PASS" ]; then
	command -v sshpass >/dev/null || { echo "Нужен sshpass для входа по паролю (mac: brew install hudochenkov/sshpass/sshpass)"; exit 1; }
	export SSHPASS="$RU_PASS"   # читается sshpass -e, в argv не попадает
	SSH() { sshpass -e ssh $HK_OPTS "$@"; }
	SCP() { sshpass -e scp $HK_OPTS "$@"; }
	# Для rsync -e: оборачиваем в sh -c, чтобы SSHPASS прокинулся в дочерний sshpass через env, не через argv.
	RSYNC_RSH="sshpass -e ssh $HK_OPTS"
else
	SSH() { ssh $HK_OPTS "$@"; }
	SCP() { scp $HK_OPTS "$@"; }
	RSYNC_RSH="ssh $HK_OPTS"
fi

# Удалённый пользователь не root → системные пути пишем через sudo.
RSH() { SSH "$SERVER" "$@"; }
SUDO_REMOTE="sudo"

# Сверяем адрес и ключ фронта с сервером ДО сборки. Иначе частый баг: фронт собран
# со старым доменом или с anon-ключом от другого сервера → Kong отвечает 401, а в
# браузере это выглядит как загадочный "Failed to fetch"/Unauthorized. Лучше упасть
# здесь с понятным сообщением, чем гонять цикл сборка→деплой→401→разбор.
check_frontend_env() {
	[ -f .env ] || { echo "  [предупреждение] нет .env в корне — пропускаю сверку адреса/ключа"; return 0; }
	local local_url local_key srv_url srv_anon
	local_url=$(grep -E '^VITE_SUPABASE_URL=' .env | head -1 | cut -d= -f2- | tr -d '"'"'"'' )
	local_key=$(grep -E '^VITE_SUPABASE_PUBLISHABLE_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"'"'"'' )
	srv_url=$(RSH "sudo grep -E '^SUPABASE_PUBLIC_URL=' /opt/supabase/docker/.env | cut -d= -f2-" 2>/dev/null | tr -d '\r')
	srv_anon=$(RSH "sudo grep -E '^ANON_KEY=' /opt/supabase/docker/.env | cut -d= -f2-" 2>/dev/null | tr -d '\r')
	local bad=0
	if [ -n "$srv_url" ] && [ "$local_url" != "$srv_url" ]; then
		echo "  ⚠ VITE_SUPABASE_URL ($local_url) ≠ адрес сервера ($srv_url)."
		echo "    Поставь в .env: VITE_SUPABASE_URL=$srv_url"; bad=1
	fi
	if [ -n "$srv_anon" ] && [ "$local_key" != "$srv_anon" ]; then
		echo "  ⚠ VITE_SUPABASE_PUBLISHABLE_KEY не совпадает с серверным ANON_KEY → будет 401 Unauthorized."
		echo "    Возьми ANON_KEY с сервера и впиши его в .env как VITE_SUPABASE_PUBLISHABLE_KEY."
		echo "    (ANON_KEY печатает server-setup.sh; или: RSH \"sudo grep '^ANON_KEY=' /opt/supabase/docker/.env\")"; bad=1
	fi
	if [ "$bad" = "1" ]; then
		echo "  Исправь .env и запусти заливку фронта заново. Сборка остановлена."
		[ "${RU_SKIP_ENV_CHECK:-0}" = "1" ] || exit 1
	fi
	echo "  [фронт] адрес и ключ совпадают с сервером ✓"
}

deploy_frontend() {
	check_frontend_env
	echo "[фронт] Устанавливаю зависимости..."
	# npm ci строгий: падает, если package-lock.json рассинхронен с package.json
	# (частая беда экспортов из Lovable). Фолбэк — npm install БЕЗ перезаписи lock-файла
	# (не меняем lock пользователя без спроса).
	if [ -f package-lock.json ]; then
		npm ci || { echo "  npm ci не прошёл (lock рассинхронен) — npm install без перезаписи lock..."; npm install --package-lock=false --no-audit --no-fund; }
	else
		npm install --no-audit --no-fund
	fi
	echo "[фронт] Собираю проект..."
	npm run build
	echo "[фронт] Заливаю на сервер..."
	# Пишем в /var/www через временную папку + sudo (rsync напрямую в /var/www прав не имеет).
	RSH "rm -rf ~/ru-deploy-dist && mkdir -p ~/ru-deploy-dist"
	if command -v rsync >/dev/null 2>&1; then
		rsync -az --delete -e "$RSYNC_RSH" dist/ "$SERVER:~/ru-deploy-dist/"
	else
		SCP -r dist/* "$SERVER:~/ru-deploy-dist/"
	fi
	RSH "$SUDO_REMOTE mkdir -p $WEB_REMOTE && $SUDO_REMOTE rsync -a --delete ~/ru-deploy-dist/ $WEB_REMOTE/ 2>/dev/null || $SUDO_REMOTE bash -c 'rm -rf $WEB_REMOTE/* && cp -r ~/ru-deploy-dist/* $WEB_REMOTE/'"
	echo "[фронт] Готово${DOMAIN:+ → https://$DOMAIN}"
}

deploy_functions() {
	[ -d supabase/functions ] || { echo "Нет папки supabase/functions — пропускаю"; return; }
	echo "[функции] Заливаю edge-функции..."
	# Собираем список функций (без системного роутера main — его трогать нельзя)
	# и проверяем имена (правило Supabase: буквы/цифры/дефис/подчёркивание), чтобы
	# ничего лишнего не ушло в удалённую команду.
	local names=""
	for d in supabase/functions/*/; do
		[ -d "$d" ] || continue
		name="$(basename "$d")"
		[ "$name" = "main" ] && continue
		case "$name" in
			*[!A-Za-z0-9_-]*|"")
				echo "  ! пропускаю '$name' — недопустимое имя функции (только A-Z a-z 0-9 _ -)"
				continue ;;
		esac
		echo "  - $name"
		names="$names $name"
	done
	[ -n "$names" ] || { echo "  нет функций для заливки"; return; }
	# Заливаем ВСЮ папку functions/ одним rsync (одно соединение — не дёргаем
	# fail2ban пачкой подключений), исключая main, в домашнюю папку. Потом одной
	# sudo-командой копируем в /opt. Это устойчивее, чем заливка по одной функции.
	RSH "rm -rf ~/ru-deploy-fn && mkdir -p ~/ru-deploy-fn"
	if command -v rsync >/dev/null 2>&1; then
		rsync -az --exclude='main/' -e "$RSYNC_RSH" supabase/functions/ "$SERVER:~/ru-deploy-fn/"
	else
		# Без rsync — копируем каждую функцию scp (по возможности всё равно одно соединение через ControlMaster)
		for name in $names; do SCP -r "supabase/functions/$name" "$SERVER:~/ru-deploy-fn/"; done
	fi
	RSH "$SUDO_REMOTE mkdir -p $FUNCS_REMOTE && $SUDO_REMOTE cp -r ~/ru-deploy-fn/. $FUNCS_REMOTE/"
	echo "[функции] Перезапускаю контейнер функций..."
	RSH "cd /opt/supabase/docker && $SUDO_REMOTE docker compose restart functions"
	echo "[функции] Готово. Если функция — публичный вебхук (без токена), добавь её имя"
	echo "          в PUBLIC_FUNCTIONS в /opt/supabase/docker/.env и перезапусти функции."
}

case "$MODE" in
	frontend) deploy_frontend ;;
	functions) deploy_functions ;;
	all) deploy_functions; deploy_frontend ;;
	*) echo "Неизвестный режим: $MODE"; exit 1 ;;
esac
