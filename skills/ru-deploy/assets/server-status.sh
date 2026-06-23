#!/usr/bin/env bash
#
# ru-deploy: статус продакшена + безопасная экономия места на сервере Cloud.ru.
# Запускать НА СЕРВЕРЕ (агент: RSH "bash ~/server-status.sh" — залей рядом, как
# server-setup.sh). Или с режимом очистки: bash server-status.sh --clean
#
#   bash server-status.sh           # только отчёт (ничего не меняет)
#   bash server-status.sh --clean   # отчёт + безопасная чистка мусора
#
# Чистка УДАЛЯЕТ только мусор: dangling-образы, build cache, обрезает огромные
# json-логи контейнеров. НЕ трогает рабочие контейнеры, тома и базу данных.

set -uo pipefail
[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"
MODE="${1:-report}"
DC="/opt/supabase/docker"

line() { printf '%s\n' "------------------------------------------"; }

echo "=========================================="
echo "  ru-deploy: статус сервера"
echo "=========================================="

# --- Состояние ВМ ---
echo ""; echo "## Машина"
echo -n "Аптайм/нагрузка: "; uptime | sed 's/.*load average/load average/'
echo "Память:"; free -h | awk 'NR==1||/Mem|Swap/'
echo "Диск:"; df -h / | awk 'NR==1||/\//'

# --- Контейнеры ---
echo ""; echo "## Контейнеры Supabase"
if command -v docker >/dev/null 2>&1; then
	# health каждого сервиса (healthy/unhealthy/restarting сразу видно)
	$SUDO docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | sort || echo "docker недоступен"
	bad=$($SUDO docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)
	restarting=$($SUDO docker ps --filter status=restarting -q 2>/dev/null | wc -l)
	[ "$bad" -gt 0 ] && echo "⚠ есть unhealthy-контейнеры: $bad — смотри логи (docker compose logs <сервис>)"
	[ "$restarting" -gt 0 ] && echo "⚠ контейнеры в restarting: $restarting — вероятно нехватка памяти (см. troubleshooting.md)"
else
	echo "Docker не установлен — backend не развёрнут."
fi

# --- Внешняя доступность (если знаем домен) ---
echo ""; echo "## Доступность снаружи"
DOMAIN="${RU_DOMAIN:-$(grep -h '^SUPABASE_PUBLIC_URL=' "$DC/.env" 2>/dev/null | head -1 | sed 's#.*//##')}"
if [ -n "${DOMAIN:-}" ]; then
	code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}:%{ssl_verify_result}' "https://$DOMAIN/rest/v1/" 2>/dev/null || echo "000:x")
	echo "https://$DOMAIN/rest/v1/ → HTTP ${code%%:*} (TLS verify ${code##*:}; 401=API жив, TLS 0=сертификат доверенный)"
else
	echo "Домен не определён (нет .env или RU_DOMAIN) — пропускаю."
fi

# --- Место: что занимает ---
echo ""; echo "## Использование места Docker"
$SUDO docker system df 2>/dev/null || true
echo "Логи контейнеров:"; $SUDO sh -c "du -ch /var/lib/docker/containers/*/*-json.log 2>/dev/null | tail -1" || echo "  (нет)"

# --- Безопасная чистка ---
if [ "$MODE" = "--clean" ]; then
	echo ""; line; echo "## Чистка мусора (данные НЕ трогаем)"; line
	# 1) dangling-образы (остаются после пересборок) и build cache
	echo "- dangling-образы и build cache:"
	$SUDO docker image prune -f >/dev/null 2>&1 && echo "  очищены"
	$SUDO docker builder prune -f >/dev/null 2>&1 && echo "  build cache очищен"
	# 2) обрезаем раздувшиеся json-логи (> 20 МБ) без остановки контейнеров
	echo "- крупные логи контейнеров (>20МБ обрезаю до 0):"
	$SUDO sh -c 'for f in /var/lib/docker/containers/*/*-json.log; do [ -f "$f" ] || continue; sz=$(stat -c%s "$f" 2>/dev/null || echo 0); if [ "$sz" -gt 20971520 ]; then : > "$f"; echo "  обрезан $(basename "$(dirname "$f")")"; fi; done' || true
	# 3) apt-кэш
	$SUDO apt-get clean >/dev/null 2>&1 && echo "- apt-кэш очищен"
	echo ""; echo "Диск после чистки:"; df -h / | awk 'NR==1||/\//'
	echo ""
	echo "ВАЖНО: НЕ запускали 'docker system prune -a' и не трогали volumes —"
	echo "это удалило бы рабочие образы Supabase и БАЗУ ДАННЫХ. Чистим только мусор."
else
	echo ""; echo "(чтобы освободить место — перезапусти с флагом --clean)"
fi

echo ""; echo "Готово."
