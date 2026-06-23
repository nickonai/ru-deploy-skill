#!/usr/bin/env python3
# ru-deploy: идемпотентный патч docker-compose.yml штатного Supabase.
#
# ЗАЧЕМ. Базовый compose из Supabase не пробрасывает в нужные сервисы пару вещей,
# без которых на self-hosted типичный Lovable-проект ломается, а агенту иначе
# приходится править YAML вручную (хрупко: кавычки/отступы/версии шаблона). Этот
# скрипт делает правки структурно и повторяемо — server-setup.sh зовёт его сам.
#
# ЧТО ДЕЛАЕТ (только если ещё не сделано — повторный запуск безопасен):
#   1. functions: добавляет `env_file: [.env]` — иначе edge-функции НЕ видят
#      секреты из .env (YOOKASSA_*, AI-ключи и т.п.).
#   2. auth: добавляет переменные кастомных писем GoTrue, если их нет:
#      GOTRUE_MAILER_SUBJECTS_* и GOTRUE_MAILER_TEMPLATES_* (русские темы/шаблоны),
#      GOTRUE_MAILER_EXTERNAL_HOSTS (домен, которому GoTrue доверяет в письмах).
#      Значения берутся из .env (${...}) — пустые переменные GoTrue игнорирует,
#      поэтому до настройки писем это ни на что не влияет.
#
# Использование:  python3 patch-compose.py /opt/supabase/docker/docker-compose.yml
import sys, re

PATH = sys.argv[1] if len(sys.argv) > 1 else "docker-compose.yml"
src = open(PATH).read()
orig = src

def child_indent(body):
    """Отступ дочерних ключей сервиса — берём из первой непустой строки тела
    (в compose Supabase это 4 пробела), чтобы не хардкодить."""
    m = re.search(r"^([ \t]+)\S", body, re.M)
    return m.group(1) if m else "    "


def find_service_block(text, name):
    """Вернуть (start, end) индексы тела сервиса `name:` (start — НАЧАЛО строки
    сразу после заголовка `name:`, end — начало следующего сервиса уровня 2
    пробела)."""
    m = re.search(rf"^  {re.escape(name)}:[ \t]*\n", text, re.M)
    if not m:
        return None
    start = m.end()  # начало строки после "  name:\n"
    nxt = re.search(r"^  \S", text[start:], re.M)  # следующий ключ уровня 2 пробела
    end = start + nxt.start() if nxt else len(text)
    return start, end


def add_env_file(text):
    """functions: добавить env_file: [.env], если его там ещё нет."""
    blk = find_service_block(text, "functions")
    if not blk:
        return text
    start, end = blk
    body = text[start:end]
    if re.search(r"^\s*env_file:", body, re.M):
        return text  # уже есть
    ind = child_indent(body)
    insert = f"{ind}env_file:\n{ind}  - .env\n"
    return text[:start] + insert + text[start:]


def add_auth_mail_vars(text):
    """auth: добавить переменные кастомных писем в блок environment:, если их нет."""
    blk = find_service_block(text, "auth")
    if not blk:
        return text
    start, end = blk
    body = text[start:end]
    # ищем строку `environment:` внутри сервиса auth (с переводом строки)
    em = re.search(r"^([ \t]*)environment:[ \t]*\n", body, re.M)
    if not em:
        return text
    env_indent = em.group(1) + "  "  # отступ для переменных = отступ environment + 2
    pos = start + em.end()  # начало строки сразу после "environment:\n"
    wanted = [
        ("GOTRUE_MAILER_EXTERNAL_HOSTS", "${MAILER_EXTERNAL_HOSTS}"),
        ("GOTRUE_MAILER_SUBJECTS_INVITE", "${MAILER_SUBJECTS_INVITE}"),
        ("GOTRUE_MAILER_SUBJECTS_CONFIRMATION", "${MAILER_SUBJECTS_CONFIRMATION}"),
        ("GOTRUE_MAILER_SUBJECTS_RECOVERY", "${MAILER_SUBJECTS_RECOVERY}"),
        ("GOTRUE_MAILER_SUBJECTS_EMAIL_CHANGE", "${MAILER_SUBJECTS_EMAIL_CHANGE}"),
        ("GOTRUE_MAILER_TEMPLATES_INVITE", "${MAILER_TEMPLATES_INVITE}"),
        ("GOTRUE_MAILER_TEMPLATES_CONFIRMATION", "${MAILER_TEMPLATES_CONFIRMATION}"),
        ("GOTRUE_MAILER_TEMPLATES_RECOVERY", "${MAILER_TEMPLATES_RECOVERY}"),
        ("GOTRUE_MAILER_TEMPLATES_EMAIL_CHANGE", "${MAILER_TEMPLATES_EMAIL_CHANGE}"),
    ]
    lines = ""
    for key, val in wanted:
        if re.search(rf"^\s*{re.escape(key)}:", text, re.M):
            continue  # такая переменная уже где-то прописана
        lines += f"{env_indent}{key}: {val}\n"
    if not lines:
        return text
    return text[:pos] + lines + text[pos:]


src = add_env_file(src)
src = add_auth_mail_vars(src)

if src != orig:
    open(PATH, "w").write(src)
    print("patch-compose: docker-compose.yml обновлён (env_file/mailer vars).")
else:
    print("patch-compose: правки уже на месте — ничего не меняю.")
