#!/usr/bin/env bash
#
# ru-deploy: применить схему базы (миграции) к серверной БД и САМ проверить,
# что она накатилась. Запускать ИЗ КОРНЯ проекта (где лежит supabase/migrations).
#
#   bash apply-migrations.sh
#
# Это отдельный обязательный шаг стадии C. Частый баг прошлых деплоев: всё залили,
# а миграции не применили → схема public пустая → сайт «работает», но падает с
# `Could not find the table 'public.<...>'` при первом входе/запросе. Поэтому
# скрипт не просто применяет, а ПРОВЕРЯЕТ результат и падает, если схема пуста.
#
# Доступ к серверу — из окружения (агент берёт из .ru-deploy/credentials.env):
#   RU_HOST (обязательно), RU_USER (по умолчанию admin), RU_PASS (если по паролю).
#
# Поведение:
#  - есть supabase/migrations/*.sql → применяет по порядку, проверяет public,
#    делает идемпотентный бэкафилл профилей (если есть таблица profiles);
#  - папки/файлов миграций НЕТ → НЕ молчит: выходит с кодом 3 и просит снять схему
#    из облака Lovable (см. backend-supabase.md → «миграций нет»). Стадию C нельзя
#    считать пройденной с пустой базой.

set -euo pipefail

RU_HOST="${RU_HOST:-}"
RU_USER="${RU_USER:-admin}"
RU_PASS="${RU_PASS:-}"
[ -n "$RU_HOST" ] || { echo "Нет RU_HOST. Запуск: RU_HOST=<IP> RU_USER=<логин> [RU_PASS=<пароль>] bash apply-migrations.sh"; exit 1; }

SERVER="$RU_USER@$RU_HOST"
DB_CONTAINER="${RU_DB_CONTAINER:-supabase-db}"

# --- ssh с переиспользованием одного соединения (как в deploy.sh) ---
KNOWN_HOSTS="${RU_KNOWN_HOSTS:-.ru-deploy/known_hosts}"
mkdir -p "$(dirname "$KNOWN_HOSTS")" 2>/dev/null || true
[ -f "$KNOWN_HOSTS" ] || : > "$KNOWN_HOSTS"
CM_DIR="${RU_CM_DIR:-.ru-deploy/cm}"
mkdir -p "$CM_DIR" 2>/dev/null || true
HK_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ControlMaster=auto -o ControlPath=$CM_DIR/%r@%h:%p -o ControlPersist=120"
if [ -n "$RU_PASS" ]; then
	command -v sshpass >/dev/null || { echo "Нужен sshpass для входа по паролю (mac: brew install hudochenkov/sshpass/sshpass)"; exit 1; }
	export SSHPASS="$RU_PASS"   # читается sshpass -e, в argv не попадает
	SSH() { sshpass -e ssh $HK_OPTS "$@"; }
else
	SSH() { ssh $HK_OPTS "$@"; }
fi
RSH() { SSH "$SERVER" "$@"; }

# psql на сервере: контейнер БД → sudo docker exec. -i для приёма SQL из stdin.
PSQL_STDIN() { RSH "sudo docker exec -i $DB_CONTAINER psql -v ON_ERROR_STOP=1 -U postgres -d postgres"; }
PSQL_C() { RSH "sudo docker exec -i $DB_CONTAINER psql -t -A -U postgres -d postgres -c \"$1\""; }

echo "=== ru-deploy: применение схемы базы ==="

# --- [0] Есть ли миграции? Если нет — останавливаемся и объясняем. ---
shopt -s nullglob
MIGRATIONS=( supabase/migrations/*.sql )
shopt -u nullglob
if [ "${#MIGRATIONS[@]}" -eq 0 ]; then
	echo ""
	echo "⚠ В проекте НЕТ файлов supabase/migrations/*.sql — применять нечего."
	echo "  Без схемы база останется пустой, и сайт будет падать на первом же запросе к БД."
	echo "  Нужно снять схему из облака Lovable/Supabase (pg_dump --schema-only) и применить её —"
	echo "  см. references/backend-supabase.md → «Вариант Б: миграций нет»."
	echo "  Стадию C (backend) НЕЛЬЗЯ считать пройденной с пустой базой."
	exit 3
fi
echo "Нашёл миграций: ${#MIGRATIONS[@]} (применяю по порядку имён)."

# --- [1] Применяем все миграции одним потоком, по порядку имён файлов ---
# Сортировка важна: имена миграций начинаются с таймстампа, порядок = хронология.
# ON_ERROR_STOP=1 (внутри PSQL_STDIN) остановит на первой реальной ошибке.
IFS=$'\n' SORTED=( $(printf '%s\n' "${MIGRATIONS[@]}" | sort) ); unset IFS
if ! cat "${SORTED[@]}" | PSQL_STDIN; then
	echo ""
	echo "✗ Миграции применились С ОШИБКОЙ (см. вывод psql выше)."
	echo "  Частые причины: повторный запуск без guard'ов (relation already exists),"
	echo "  ссылка на роль/расширение, которых нет. Исправь миграцию и запусти заново."
	echo "  Идемпотентные миграции (CREATE TABLE IF NOT EXISTS / DROP ... IF EXISTS) переживают повтор."
	exit 2
fi

# --- [2] САМОПРОВЕРКА: схема public не пустая ---
# Это и есть «ворота»: без таблиц дальше идти нельзя.
COUNT="$(PSQL_C "select count(*) from information_schema.tables where table_schema='public';" | tr -d '[:space:]')"
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
if [ "$COUNT" -eq 0 ]; then
	echo ""
	echo "✗ После применения в схеме public НЕТ таблиц. Миграции не создали схему"
	echo "  (возможно, создают объекты в другой схеме, или применились не к той базе)."
	echo "  Разберись по выводу выше — не продолжай на пустой базе."
	exit 2
fi
echo "✓ Схема накатилась: таблиц в public — $COUNT."
echo "  Список:"
PSQL_C "select tablename from pg_tables where schemaname='public' order by tablename;" | sed 's/^/    - /'

# --- [3] Бэкафилл профилей для уже зарегистрированных пользователей ---
# Типовая схема Lovable создаёт profiles ТРИГГЕРОМ на новую регистрацию. Если кто-то
# зарегистрировался до применения схемы — у него нет профиля и приложение падает.
# Делаем только если таблица public.profiles существует. Идемпотентно (on conflict).
HAS_PROFILES="$(PSQL_C "select 1 from information_schema.tables where table_schema='public' and table_name='profiles' limit 1;" | tr -d '[:space:]')"
if [ "$HAS_PROFILES" = "1" ]; then
	echo "Бэкафилл профилей для существующих пользователей (идемпотентно)..."
	# Колонки profiles бывают разные; вставляем только id (обычно NOT NULL/PK), остальное
	# заполнят дефолты/последующие апдейты. Если у profiles есть другие NOT NULL без default —
	# скрипт сообщит об ошибке, и это правят точечно (см. backend-supabase.md).
	echo "insert into public.profiles (id) select id from auth.users on conflict (id) do nothing;" | PSQL_STDIN \
		&& echo "  профили синхронизированы." \
		|| echo "  ⚠ бэкафилл не прошёл (вероятно, у profiles есть обязательные колонки кроме id) — допиши select под свою схему, см. backend-supabase.md."
	# PostgREST держит схему в кэше — после изменения структуры перечитываем.
	RSH "cd /opt/supabase/docker && sudo docker compose restart rest" >/dev/null 2>&1 || true
fi

echo ""
echo "=== Готово: схема применена и проверена. ==="
echo "Это ворота стадии C: можно переходить к фронту (стадия D) — таблицы на месте."
