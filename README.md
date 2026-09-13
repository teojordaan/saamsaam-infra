# saamsaam-infra

Everything needed to run SaamSaam on a server: compose files, env config, nginx,
and the built web assets.

## The private / public split

The stack is split across two compose files, because a server may already
provide some of it.

| File | Services | Runs when |
|---|---|---|
| `compose.yml` | `api` | Always. Ours on every host. One instance per box. |
| `public/compose.yml` | `nginx`, `postgres`, `redis` | Only on a host that has none of its own. |

A box runs **one** SaamSaam instance; whether it is dev or live is decided by
which box it is — its own domain, database and bot token, all carried by its
generated `.env`. There is no second `api-staging` service.

On a box running local-infra (or gentick-infra), `public/` stays down and the
api reaches the existing services over `backend-net`. On a bare box, both files
come up and the stack is self-contained.

Everything joins one network, `backend-net`, so `POSTGRES_HOST=postgres`
resolves to whichever postgres is running without an env change.

The network is declared `external` in both files and created by `svc-start.sh`.
Compose has no conditional and refuses to adopt a network it did not create, so
"use it if it exists, otherwise create it" cannot be expressed in the compose
file. Starting by hand needs it first:

```bash
docker network create backend-net
```

> **Do not run `public/` on a host that already has these services.** Two
> containers cannot both answer to `postgres` on one network — you get a name
> collision, or the wrong database.

## Bringing it up

```bash
./svc-build-env.sh
docker compose --env-file .env -f compose.yml up -d
```

Standalone, add the backing services first:

```bash
cd public && docker compose --env-file ../.env -f compose.yml up -d
```

`svc-start.sh` wraps both with health checking and scope flags.

### `--env-file` is not optional

Compose resolves `${...}` from the `.env` beside the **first `-f` argument**, and
running from the repo root does not change that — for `public/compose.yml` it
looks in `public/`, finds nothing, and every `${VAR}` falls to its default or an
empty string with a warning.

`public/compose.yml` therefore declares its credentials as `${VAR:?message}`, so
a forgotten `--env-file` fails immediately and says what to do instead of
silently initialising a database with an empty password.

Note that `env_file:` and `--env-file` are different mechanisms: `env_file:`
hands variables to a container at runtime and does **not** feed `${...}`.

## Environment

`.env` is built by `svc-build-env.sh` and never committed. It is the **single**
env layer — there are no committed `.env.live`/`.env.staging` overlays any more,
because a box runs one instance and its per-box identity (domain, database name,
bot token) comes from its own pragma. `PUBLIC_BASE_URL` is marked `replace` so
each box must declare its own; getting it wrong emails users links to the wrong
site.

`PROJECT_NAME` is the root variable — the project data root and the database
name derive from it.

The postgres settings are a single set of `POSTGRES_*` variables, read by both
the postgres container and the API. There is no second `PG_*` set: two names for
one fact is how you get a database initialised with one credential and an API
dialling with another.

The two ports are independent and easy to confuse:

- **`POSTGRES_PORT`** — the port postgres listens on. It reaches the container as
  `PGPORT`, is the container side of the published mapping, and is what the API
  dials. Change it and all three move together.
- **`POSTGRES_HOST_PORT`** — where that port is published on `127.0.0.1`, for
  psql over an ssh tunnel and for the Go test suite. A published port does not
  exist for container-to-container traffic, so the API never uses it.

It is `PGPORT` on the container rather than `POSTGRES_PORT` because the
`POSTGRES_*` names are the image's own init variables, while the listen port
belongs to postgres itself — libpq has read `PGPORT` since long before the image
existed. That is also why the postgres healthcheck needs no `-p` flag.

`REDIS_PORT` / `REDIS_HOST_PORT` work the same way, but redis has no `PGPORT`
equivalent, so the port is a `command:` flag. **`redis-cli` does not infer it**
— with no `-p` it tries 6379 regardless — so its healthcheck carries the port
explicitly. Without that, moving `REDIS_PORT` would mark a perfectly healthy
redis unhealthy and `svc-start.sh` would report a broken stack.

> **A literal `$` in a secret must be doubled.** Compose interpolates `.env`, so
> `pa$word` reaches the container as `pa`. `svc-build-env.sh` handles this; by hand,
> write `pa$$word`. Compose only warns, so a missed one surfaces later as a
> credential that is simply wrong.

### Secrets

**A value starting with `replace` is what marks a variable as host-supplied.**
That is the whole rule, so the template is the single declaration of what needs
filling — `SMTP_USER=replace@me.com` needs a secret, `LOG_LEVEL=info` is passed
through untouched. The mark is not only for secrets: `PUBLIC_BASE_URL` holds no
secret at all, but it differs per box and emailing the wrong domain is silent
damage, so it is forced per host the same way.

Secrets live in **one file** on the box:

```
/srv/data/pragma        KEY=value per line, mode 600, owned by the deploy user
```

```
POSTGRES_USER=gentick
POSTGRES_PASSWORD=s3cr3t
API_JWT_SECRET_SAAMSAAM=0f3a...
PUBLIC_BASE_URL=https://sm.teojordaan.com
```

The path is fixed and deliberately does **not** follow `HOST_DATA_ROOT`. That
variable exists so bulk data — a postgres cluster — can be moved onto a second
drive; secrets are a few kilobytes and never grow. When they moved together,
compose read the root from `.env` and the script read it from the shell, and on
exactly the hosts that had a data drive the two silently disagreed.

Owned by the **deploy user**, not root: this script runs as whoever deploys, so
a root-owned file is `Permission denied` on the read. Running the whole thing
under `sudo` does not fix it — that writes a root-owned `.env`, which compose
then cannot read back. Mode `600` keeps every other account out either way.

A duplicate key is an error rather than last-wins, and so is a line that is
neither `KEY=value`, a `#` comment, nor blank — a typo like
`POSTGRES PASSWORD=x` would otherwise be ignored and surface weeks later as a
login failure. Values split on the **first** `=` only, so a base64 secret ending
in `==` survives intact.

> This replaced a directory of one-file-per-secret in svc-scripts 0.1.0, and
> there is **no fallback** to it. A box still carrying `/srv/data/creds` is
> migrated once, with the loop in the header of `svc-build-env.sh`; the script
> detects the old directory and refuses with that instruction rather than
> building a `.env` out of nothing.

The file is **flat and shared by every project on the box**, keyed on the
variable name alone. Which gives the rule that decides how to name a secret:

> **A variable's name must be unique exactly when its value must be unique.**

`POSTGRES_USER` is one database role serving several databases, so it is one key,
shared. A JWT signing key is not — rms and talosot are separate services, and one
shared `API_JWT_SECRET` would let a token minted by either verify against the
other. So they are `API_JWT_SECRET_RMS` and `API_JWT_SECRET_TALOSOT`; SaamSaam's
is `API_JWT_SECRET_SAAMSAAM`, mapped to the `API_JWT_SECRET` the image actually
reads by the `environment:` block in `compose.yml`.

Note the name must be **static**. `${PROJECT_NAME}_JWT_SECRET` does not match the
`^[A-Za-z_][A-Za-z0-9_]*=` line the template walk looks for, so it would be
passed through verbatim — and the missing-secret check only fires for lines that
matched, so the build would report success and write a live placeholder.

The pragma file is deliberately outside this repo and must be placed by hand,
once per server. The script appends to it but will not create it.

| Invocation | Does |
|---|---|
| `./svc-build-env.sh` | Build `.env`. If keys are missing, lists them and offers to stub them. |
| `./svc-build-env.sh --defaults` | Same, but never asks — takes the yes. |
| `./svc-build-env.sh --init-pragma` | Only append the stubs. Never builds `.env`. |
| `./svc-build-env.sh --check` | Report only. Writes nothing at all, not even stubs. |

A stub holds the template placeholder verbatim, so `API_JWT_SECRET_SAAMSAAM`
arrives as `replace-me-with-a-32-byte-minimum-secret` — the shape of the wanted
value, in the file you are about to edit. It **never** touches a key that is
already present, whatever it holds, and the build refuses any value still
holding a placeholder. That refusal is what makes offering to scaffold safe at
all.

## The database

`POSTGRES_DB` (`saamsaam`) is created by the postgres image on **first boot
only**. One instance per box means one database — there is no second staging
database to create by hand any more.

Changing `POSTGRES_PASSWORD` after first boot does **not** change the password in
the database — the variable is ignored on every later start. Use `ALTER ROLE`.

## Data

Two roots, at two different scopes:

| Variable | Default | Scope |
|---|---|---|
| `HOST_DATA_ROOT` | `/srv/data` | The host. Shared by every project on the box. |
| `PROJECT_DATA_ROOT` | `${HOST_DATA_ROOT}/${PROJECT_NAME}` | This project alone. |

```
/srv/data/
  pragma        host   the secrets FILE (not a directory), read by svc-build-env.sh
  certs/        host   TLS, read by nginx
  postgres/     host   the postgres cluster — every project's databases
  redis/        host
  saamsaam/     project
```

**postgres and redis write to the host root, not the project one.** A postgres
data directory holds a whole *cluster*: `saamsaam` and any future project's
databases all live in it. Filing that under one project's
folder would put project B's data inside project A's.

`PROJECT_DATA_ROOT` is for files that genuinely belong to one project — user
uploads, exports, backups. Nothing uses it yet; it is defined so the convention
exists before the first thing that needs it invents a different one.

Both are outside the repo, and outside any Windows-mounted path.

> On a Windows dev box this matters: anything under `/mnt/c/...` is DrvFs, which
> has no real `chmod`, and `initdb` refuses to run there. `/srv/data/...` from
> inside WSL is the VM's own ext4, so it works. Reach it from Windows at
> `\\wsl$\<distro>\srv\data\`.

## The two boxes

SaamSaam runs one instance per box, and there are two.

| | Dev | Live |
|---|---|---|
| Host | this workstation (WSL Ubuntu) | `rek.teojordaan.com` — a Windows PC, WSL Ubuntu-24.04 |
| Domain | `sm.teojordaan.com` | `saamsaam.archyta.com` |
| Backing services | `local-infra` provides them | **nothing does** — this repo brings its own |
| Scope | `./svc-start.sh --scope private` | `./svc-start.sh --scope all` |
| Tunnel | — | `cloudflared`, a Windows service, dialling `localhost:8080` |

Nothing in this repo says which box is which. The whole difference is the box's
own `/srv/data/pragma`: `PUBLIC_BASE_URL`, `TELEGRAM_BOT_TOKEN` and the database
credentials. So the same commit deploys to either, and the mistake that would
hurt — a live box emailing links to the dev domain — is caught by
`svc-build-env.sh` refusing to write a `.env` with `PUBLIC_BASE_URL` unfilled.

> **The Telegram tokens must differ.** `getUpdates` is single-consumer per token:
> two boxes polling the same bot 409-fight each other and neither works reliably.
> A box that should not run Telegram at all leaves the pragma key empty — the api
> reads that as "disabled", logs it, and starts no poller.

### Standing up the live box

The backing services come from this repo there, so it is the `--scope all` path.
Everything below is one-off, per box:

1. `dockerd` running in WSL. The distro has `systemd=false`, so it does not start
   itself.
2. `/srv/data/pragma` — mode 600, owned by the deploy user, holding the keys
   `svc-build-env.sh --check` names. `POSTGRES_*`, `REDIS_PASSWORD`, `SMTP_*`,
   `API_JWT_SECRET_SAAMSAAM`, the `TELEGRAM_*` set, and `PUBLIC_BASE_URL`.
3. `git clone` this repo to `/srv/saamsaam-infra` — inside the WSL filesystem,
   never under `/mnt/c`. DrvFs has no real `chmod` and `initdb` refuses to run
   there; the compose file looks fine and the real error is three levels down in
   `docker logs`.
4. `docker login ghcr.io`, once, so `svc-update.sh` can pull the api image.
5. `./svc-build-env.sh` then `./svc-start.sh --scope all`.
6. The Cloudflare tunnel's public hostname points at `http://localhost:8080`.
   WSL2 forwards a published port to the Windows host, which is how a cloudflared
   running as a Windows service reaches nginx inside the VM.

`POSTGRES_DB` is honoured on **first boot only**, so step 5 creates the
`saamsaam` database exactly once — on a box whose postgres cluster already
existed, create it by hand instead.

## Domains

TLS is terminated by the Cloudflare tunnel in front of nginx, so nginx listens
on port 80 and publishes it as `8080` on the host. There is no `listen 443` and
no certs mount; both were removed once it was clear nothing terminated TLS here.

One instance per box means one domain per box, served by a single nginx server
block (`server_name _`, a catch-all) that proxies `/api/` to `saamsaam-api:8080`.
The box's public domain is declared in the api's `PUBLIC_BASE_URL` — the domain
in emailed links — and is deliberately not pinned in nginx, so the same config
serves either box.

nginx addresses the api by **container** name. Compose gives a container both its
container name and its service name as network aliases, and either resolves
across compose projects — but the service name is the bare word `api`, which
would collide with any other stack on the network.

## The web bundle

The built Flutter web app is committed to **one** directory:

```
public/nginx/html/saamsaam/
```

One directory, because a box runs one instance. There is no
`html/saamsaam-staging` any more — that folder existed only to let one box serve
two instances on two domains, and the two bundles drifted: the one nginx mounted
went stale while every new build landed in the other.

It is committed rather than built on the server because commit → push → pull is
the only way files reach a box. `public/compose.yml` bind-mounts it read-only
into nginx, so a standalone box serves it with no extra step. On a box where a
shared provider owns nginx — `local-infra` here, `gentick-infra` on a server —
the same bundle is copied into that stack's `nginx/html/saamsaam`.

`.gitattributes` marks the whole directory `-text`, so git stores it as opaque
bytes. Without that, `text=auto` autodetects the `.js`/`.json`/`.html` in it as
text and rewrites their line endings on the round trip — the file nginx serves is
then not the file that was built and tested, and a bundle whose content hashes
stop matching its bytes fails silently rather than loudly.

Build it with `agollum/flutter/build-web.sh`. That script still offers a
`staging` / `production` split, which for this repo selects only the output
folder name, so **pass `--out` at this directory explicitly** rather than letting
its probe pick `html/saamsaam-staging` back into existence.

## Scripts

| Script | Purpose |
|---|---|
| `svc-build-env.sh` | Build `.env` from `.env.example` + the box's pragma file |
| `svc-start.sh` | Bring services up and wait for health |
| `svc-stop.sh` | Stop them |
| `svc-update.sh` | Pull new images and recreate |
| `svc-image-purge.sh` | Remove images from the local cache |
| `svc-compose.sh` | Shared helpers, sourced by the others |

The `svc-*.sh` set is **version 0.1.1**, and the canonical copies live in
`agollum/docker/services/`. Edit them there and copy the whole set across — a server
only ever pulls this repo, so it needs its own copy, but a half-updated set
fails in ways that look like a bug in the file you did not touch.

They all take `--scope`, and `private`/`public` mean the same thing everywhere:
a compose file, not a registry.

| Scope | Means |
|---|---|
| `private` | `compose.yml` — the api containers |
| `public` | `public/compose.yml` — nginx, postgres, redis |
| `all` | both (start/stop/update only) |
| `host` | every image on the machine (purge only) |

`--scope private` is the default for start, stop and update. None of them names
a service: the compose file is the list, which is why they kept working when the
services were renamed. `--scope all` starts public before private and stops them
in reverse.

`svc-image-purge.sh` removes **every** tag of the images a compose file names,
not just the one currently pinned — old tags are what take up the space. Images
backing an existing container are skipped and reported rather than forced.
`--dry-run` lists without removing.

### Registry access

`svc-update.sh` does not handle registry credentials. Run this once per host:

```bash
docker login ghcr.io
```

Docker stores the credential itself. No PAT belongs in `.env` — it would sit in
plaintext on every machine holding a copy of this repo, in the first file anyone
would look in.

## Running the tests

From `agollum/testing`:

```bash
./golang.sh --app ../../personal/SaamSaam/saamsaam-api --infra ../../personal/SaamSaam/saamsaam-infra --scope public --defaults
```

It starts the public services on **`.env.example` verbatim** — same ports, same
container names, same data root a deploy uses — so a test run on a dev box is
the same shape as the local server rather than a special case that can pass
while the real thing fails. There is no separate test env file.

The suite opens with `DROP SCHEMA public CASCADE`, so it wants a throwaway
database. That is fine here by design: this machine is for dev and test, and
anything that needs to persist gets deployed to the local server. Services are
left running afterwards, and `/srv/data` survives, so a failure can be inspected.

## Deploying

Commit → push → pull on the server. That is the only way files reach it.

- **Frontend only** — the bundle is in the repo, so pulling is the deploy. nginx
  serves the bind-mounted directory immediately; no rebuild, no registry, no
  restart.
- **Backend** — build and push the `saamsaam-api` image to GHCR, move
  `API_IMAGE_TAG` in the tracked `.env.example`, commit, push, pull, then on the
  box:

  ```bash
  ./svc-build-env.sh          # <- NOT optional. See below.
  ./svc-update.sh
  ```

  The tag lives in a tracked file so the deployed version is visible in git
  history; pinning it in the gitignored `.env` would hide it.

  > **Rebuilding `.env` is the step that is easy to skip and silent when you do.**
  > `svc-build-env.sh` copies every non-secret line of `.env.example` through
  > verbatim, so the generated `.env` holds its own copy of `API_IMAGE_TAG` — and
  > compose reads `.env` **before** the `${API_IMAGE_TAG:-0.0.0}` default in
  > `compose.yml`. `svc-update.sh` checks that `.env` exists but never regenerates
  > it. So a pull that brings a new tag, followed straight by `svc-update.sh`,
  > cheerfully re-pulls and redeploys the version that was already running, and
  > reports success.

A box is dev or live by virtue of being that box. Nothing in this repo says
which — the difference is entirely in the box's own `/srv/data/pragma`
(`PUBLIC_BASE_URL`, `TELEGRAM_BOT_TOKEN`, the database credentials), so the same
commit deploys to either.
