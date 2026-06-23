#!/usr/bin/env python3
"""Генерация HS256-JWT для self-hosted Supabase (ANON_KEY / SERVICE_ROLE_KEY).

Использование:
    python3 gen-keys.py <JWT_SECRET> <role>
где role = anon | service_role

Печатает готовый JWT в stdout. Никаких внешних зависимостей — только stdlib.
"""
import sys, hmac, hashlib, base64, json, time


def b64url(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def make_jwt(secret: str, role: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    iat = int(time.time())
    exp = iat + 10 * 365 * 24 * 60 * 60  # 10 лет
    payload = {"role": role, "iss": "supabase", "iat": iat, "exp": exp}
    seg = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + b"."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    sig = b64url(hmac.new(secret.encode(), seg, hashlib.sha256).digest())
    return (seg + b"." + sig).decode()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: gen-keys.py <JWT_SECRET> <anon|service_role>")
    print(make_jwt(sys.argv[1], sys.argv[2]))
