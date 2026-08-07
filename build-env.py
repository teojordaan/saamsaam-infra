#!/usr/bin/env python3
"""Build .env from .env.example by reading secrets from the Windows certs/ dir.

Usage (from WSL, inside ~/Server-Infra):

    python3 build-env.py           # → .env  (template + secrets)

Only run this when secrets change (certs/ files or .env.example).
Env-specific config lives in .env.live and .env.staging — those
are committed and never touched by this script.
"""

import os
import re

CERTS_DIR = "/mnt/c/dev/certs"
TEMPLATE = ".env.example"
OUTPUT = ".env"

# Map env vars → cert filenames
MAPPING = {
    "GHCR_USER": "github_username.txt",
    "GHCR_PAT": "github_pat.txt",
    "PG_USER": "pg_username.txt",
    "PG_PASSWORD": "pg_password.txt",
    "API_JWT_SECRET": "jwt_secret.txt",
    "SMTP_USER": "smtp_user.txt",
    "SMTP_PASSWORD": "smtp_password.txt",
    "SMTP_FROM": "smtp_from.txt",
    "TELEGRAM_BOT_TOKEN": "telegram_token.txt",
}


def read_cert(filename):
    """Read a cert file, strip BOM + whitespace, return first non-empty line."""
    path = os.path.join(CERTS_DIR, filename)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:3] == b"\xef\xbb\xbf":
        raw = raw[3:]
    return raw.decode("utf-8").strip()


# ── Load secrets ───────────────────────────────────────
secrets = {}
for var, filename in MAPPING.items():
    value = read_cert(filename)
    if value is not None:
        secrets[var] = value
    else:
        print(f"  ⚠  {filename} not found — {var} left as default", file=__import__('sys').stderr)

# ── Read template ──────────────────────────────────────
with open(TEMPLATE, encoding="utf-8") as f:
    content = f.read()


def replace_var(match):
    """Replace matched VAR=... with VAR=<secret>."""
    var = match.group(1)
    if var in secrets:
        value = secrets[var].replace("$", "$$")
        return f"{var}={value}"
    return match.group(0)


# Match non-commented VAR=value lines
pattern = re.compile(r"^(?!\s*#)(\w[\w_]*)=.*$", re.MULTILINE)
result = pattern.sub(replace_var, content)

# ── Write output ───────────────────────────────────────
with open(OUTPUT, "w", encoding="utf-8") as f:
    f.write(result)

print(f"  ✓  {OUTPUT} written ({len(secrets)} secrets filled)")
