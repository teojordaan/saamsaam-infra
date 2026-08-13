# Unreleased

### Fixed

- **The API and postgres were given different credentials.** `.env.example`
  carried both `POSTGRES_*` (read by the postgres image) and `PG_*` (read by the
  API) as independent values, and they disagreed — a fresh clone initialised the
  database with one username and dialled it with another. The `PG_*` set is gone
  entirely: the API now reads `POSTGRES_*`, so there is one set of names and
  nothing left to keep in agreement. Requires the matching `saamsaam-api`
  change — an older image reading `PG_HOST` will panic on boot.
- **nginx proxied to two containers that no longer exist.** The upstreams were
  still `go-api` and `go-api-staging` after the rename to `api`/`api-staging`.
  Because `proxy_pass` used a variable, nginx started clean and every `/api/`
  request 502'd instead. Now addressed by container name.
- **`public/compose.yml` silently ignored `.env`.** Compose resolves `${...}`
  from the `.env` beside the first `-f` argument, so running from the repo root
  did not help. Credentials are now `${VAR:?message}`, making a forgotten
  `--env-file` a hard error that names the fix.
- **Debugging scripts were being served from the public web root.** Five `.py`
  files had been swept into the Flutter build output in both document roots.
- Shell scripts are pinned to LF. `text=auto` alone checked them out with CRLF on
  Windows, so a clean clone could not run its own scripts under WSL.

### Changed

- `postgres` and `redis` take their configuration through `${...}` instead of
  `env_file: ../.env`, which had been handing the postgres container every
  secret in the repo — SMTP password, JWT secret and Telegram token included.
- `redis` moves from a named volume to a bind mount under `${HOST_DATA_ROOT}`,
  matching postgres, so all service data sits in one place.
- Both compose files declare a project `name:`. Without it the names defaulted to
  the directory, making `public/` the compose project `public` and its volume
  `public_redis-data`.
- `build-env.py` becomes `svc-build-env.sh`, so a server needs no Python. Secrets are
  read from `/srv/data/creds` by a filename derived from the variable name rather
  than a lookup table — the old table had drifted, mapping two variables absent
  from the template. It now refuses to write a `.env` that still contains a
  placeholder, and names the cred files to create.
- `.env.example` documents which variables configure a container and which are
  read by the API. `POSTGRES_PORT` is now genuinely wired: it is fed to the
  container as `PGPORT`, used as the container side of the published port
  mapping, and dialled by the API — three consumers of one value. Previously it
  was read only by the API while the container was hardcoded to 5432, so
  changing it pointed the API at a dead port and moved nothing else.
  `POSTGRES_HOST_PORT` remains independent: it is where that port is published
  on the host, and a published port does not exist for container-to-container
  traffic.

  `PGPORT` rather than `POSTGRES_PORT` on the container because the `POSTGRES_*`
  names are the image's own init variables, while the listen port belongs to
  postgres itself — libpq has read `PGPORT` since long before the image. It also
  means the healthcheck needs no `-p` flag.

- `REDIS_PORT` is wired the same way. Redis has no `PGPORT` equivalent, so it is
  a `redis-server --port` flag, and the healthcheck passes `-p` explicitly:
  `redis-cli` does **not** infer the port the way `pg_isready` does, so without
  the flag a moved port would leave a healthy redis permanently unhealthy. The
  published port mapping is parameterised on both sides.

- `NGINX_HOST` added to the template, matching the container name
  `public/compose.yml` already parameterised.
- README rewritten — it documented a `Server-Infra` directory, a
  `docker-compose.yml`, and routes to `go-api`, none of which exist.

- `APPNAME` is renamed `PROJECT_NAME`, and the data roots split by scope.
  `HOST_DATA_ROOT` is now `/srv/data` — a property of the host, shared by every
  project on it — with `PROJECT_DATA_ROOT` derived beneath it. It previously
  read like a host-level variable while holding an app-level path, which is why
  `svc-build-env.sh`'s creds directory sat outside it with no relationship to it.

  postgres, redis, certs and creds all live under the **host** root. A postgres
  data directory holds a whole cluster, so every project's databases share one —
  putting it under a project folder would file project B's data inside project
  A's. `PROJECT_DATA_ROOT` has no consumer yet and is defined so that the first
  thing needing per-project storage does not invent a different convention.

- **`GHCR_USER` and `GHCR_PAT` are gone from `.env`.** A registry PAT in a
  template file sits in plaintext on every machine holding a copy of the repo,
  in the first file anyone would look in. `svc-update.sh` no longer logs in at
  all: run `docker login ghcr.io` once per host and docker keeps the credential.
  A failed pull now says so and gives the command.

- **Networking collapsed to one network.** Everything joins `backend-net`,
  declared external in both files and created by `svc-start.sh`. The per-project
  network bought nothing — container names are already globally unique — and
  cost real confusion: compose refuses to adopt a network it did not create, so
  a network owned by `compose.yml` made `public/compose.yml` unstartable on its
  own, which is exactly what the test runner does.

- **The service scripts no longer name services.** `svc-start.sh`,
  `svc-stop.sh` and `svc-update.sh` take `--private` (default), `--public` or
  `--all` and act on a whole compose file, sharing a new `svc-compose.sh`. The
  old hardcoded `PRIVATE_SVCS=(go-api …)` array is why they were still starting
  a service that had not existed since the rename. `--all` waits for public to
  be healthy before starting private and stops them in reverse.

- Placeholders in `.env.example` are now `replace-me` / `replace@me.com`.
  `API_JWT_SECRET`'s keeps 32+ bytes so the api still boots on the template.

- **Every script takes `--scope private|public|all`,** and the words mean the
  same thing in all of them. `svc-image-purge.sh` used them for a *registry*
  (ghcr.io vs Docker Hub), which selected the same images only because
  `compose.yml` happens to hold the ghcr one — the day that stopped being true,
  the same word would have purged the other half. It now derives its list from
  the compose files, removes **every** tag rather than only the pinned one, and
  gained `--scope host` for the pan-machine sweep that used to hide behind
  `all`, plus `--dry-run`.

- **`svc-build-env.sh` decides what is a secret from the template.** A value
  starting with `replace` needs a cred file; anything else is passed through.
  Previously it looked for a cred file for *every* variable, so a stray
  `log_level.txt` would silently override a non-secret. Cred filenames are now
  case-insensitive with an optional `.txt`, two files claiming one secret is an
  error rather than a coin toss, and a cred file still holding the placeholder
  text is caught rather than written through.

- `svc-common.sh` is `svc-compose.sh` — it wraps `docker compose`, and
  "composer" is a different tool entirely. `build-env.sh` is `svc-build-env.sh`.

### Notes

- A literal `$` in any secret must be doubled. Compose interpolates `.env`, so
  `pa$word` reaches the container as `pa`, with a warning and no error.
  `svc-build-env.sh` does this escaping.
- The staging database is still created by hand. `POSTGRES_DB` is honoured on
  first boot only, and an init script would not run against an existing data
  directory.
