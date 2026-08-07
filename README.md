# Server-Infra — Docker Compose stack

The deployment orchestrator for SaamSaam. Contains everything needed to run the
app on a single VPS: Docker Compose services, env config, nginx, and built web
assets.

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| `nginx` | `nginx:alpine` | Reverse proxy + static file server. Two server blocks: staging (`sm.teojordaan.com`) and live (`saamsaam.archyta.com`). Configs are volume-mounted. |
| `go-api` | `ghcr.io/teojordaan/saamsaam-api` | Production API (live) |
| `go-api-staging` | `ghcr.io/teojordaan/saamsaam-api` | Staging API — same image, different DB + config |
| `postgres` | `postgres:17-alpine` | Shared PostgreSQL instance. Both staging and live use separate databases in the same instance. |
| `redis` | `redis:7-alpine` | Session cache, rate limiting |

## Directory layout

```
Server-Infra/
├── docker-compose.yml   # Parameterised compose — no hardcoded env values
├── .env                 # Built by build-env.py (gitignored)
├── .env.staging         # Staging overrides (PG_DB, PUBLIC_BASE_URL, LOG_LEVEL)
├── .env.live            # Live overrides (PG_DB, PUBLIC_BASE_URL)
├── nginx/
│   ├── nginx.conf       # Single config — both staging + live server blocks
│   └── ...              # SSL certs (not tracked in git)
├── data/
│   └── postgres/        # PostgreSQL data directory (gitignored, docker volume)
└── svc-*.sh             # Scripts: start, stop, update
```

## Domains

| Domain | Target | Via |
|--------|--------|-----|
| `sm.teojordaan.com` → | `go-api-staging:8080` | Cloudflare tunnel → nginx |
| `saamsaam.archyta.com` → | `go-api:8080` | Cloudflare tunnel → nginx |

## Deploy

Deployment happens via GitHub push → WSL git pull.
See `scripts/windows/deploy-full-staging.sh` (default) or `deploy-full-live.sh`.

## Secrets

All secrets live in `C:\dev\certs\` on the host, consumed by `build-env.py`.
Never commit secrets to this repo.
