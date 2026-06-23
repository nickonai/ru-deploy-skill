#!/usr/bin/env bash
#
# ru-deploy: сменить домен backend на сервере (все серверные места разом).
# Запускать НА СЕРВЕРЕ: bash set-domain.sh <новый-домен>
# Пример: bash set-domain.sh fit-food-demo.ru
#
# Меняет ВСЕ серверные URL Supabase Auth + домен Caddy и перезапускает нужные
# сервисы. Это закрывает частый баг: поменяли домен не везде → фронт/Auth
# стучатся по старому адресу → "Failed to fetch".
#
# ВАЖНО: фронт (VITE_SUPABASE_URL) этот скрипт НЕ трогает — его меняет агент в
# локальном .env проекта и пересобирает (deploy.sh frontend). Без пересборки
# в собранном JS остаётся старый адрес.

set -euo pipefail
[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"

DOMAIN="${1:-}"
[ -n "$DOMAIN" ] || { echo "Укажи домен: bash set-domain.sh <домен>"; exit 1; }
ENV_FILE="/opt/supabase/docker/.env"
[ -f "$ENV_FILE" ] || { echo "Нет $ENV_FILE — backend не установлен"; exit 1; }

set_env() {
	$SUDO python3 - "$1" "$2" "$ENV_FILE" <<'PY'
import sys, os
os.umask(0o077)
key, val, fn = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(fn).read().splitlines()
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
	$SUDO chmod 600 "$ENV_FILE" 2>/dev/null || true
}

echo "Меняю домен Supabase на https://$DOMAIN ..."
# ВСЕ внешние URL, где встречается домен. Пропустишь хоть один — будет рассинхрон.
set_env SITE_URL                "https://$DOMAIN"
set_env API_EXTERNAL_URL        "https://$DOMAIN"
set_env SUPABASE_PUBLIC_URL     "https://$DOMAIN"
set_env ADDITIONAL_REDIRECT_URLS "https://$DOMAIN/**"
# Домен, которому GoTrue доверяет в ссылках из писем — тоже на новый, иначе
# ссылки подтверждения/сброса могут указывать на старый домен.
set_env MAILER_EXTERNAL_HOSTS   "$DOMAIN"
# Если в письмах прописаны шаблоны по URL (MAILER_TEMPLATES_*), они тоже содержат
# старый домен — переориентируем на новый (только непустые).
for k in MAILER_TEMPLATES_CONFIRMATION MAILER_TEMPLATES_RECOVERY MAILER_TEMPLATES_EMAIL_CHANGE MAILER_TEMPLATES_INVITE; do
	cur="$($SUDO grep -E "^$k=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
	[ -n "$cur" ] || continue
	new="$(printf '%s' "$cur" | sed -E 's#https://[^/]+#https://'"$DOMAIN"'#')"
	set_env "$k" "$new"
done

# Caddy обслуживает новый домен: подменяем DOMAIN у контейнера и перезапускаем.
echo "Перенастраиваю Caddy на $DOMAIN (выпустит новый HTTPS-сертификат)..."
$SUDO docker rm -f caddy >/dev/null 2>&1 || true
$SUDO docker run -d --name caddy --restart unless-stopped --network host \
	-e DOMAIN="$DOMAIN" \
	-v /etc/caddy/Caddyfile:/etc/caddy/Caddyfile \
	-v /var/www/app:/var/www/app \
	-v caddy_data:/data -v caddy_config:/config \
	caddy:2 >/dev/null

echo "Перезапускаю Supabase Auth и Kong (с пересозданием — чтобы перечитали новые URL)..."
cd /opt/supabase/docker
# --force-recreate обязателен: без него `up -d` не пересоздаёт контейнер, если его
# конфиг не менялся, и новые значения из .env не подхватываются.
$SUDO docker compose up -d --force-recreate auth kong rest

echo ""
echo "Готово на сервере. Проверка через ~30 сек:"
echo "  curl -sS -o /dev/null -w '%{http_code} TLS=%{ssl_verify_result}\\n' https://$DOMAIN/auth/v1/health"
echo ""
echo "НЕ ЗАБУДЬ ФРОНТ: в локальном .env проекта поставь"
echo "  VITE_SUPABASE_URL=https://$DOMAIN"
echo "и пересобери+залей: bash deploy.sh frontend $DOMAIN"
echo "Иначе в собранном сайте останется старый адрес и будет 'Failed to fetch'."
