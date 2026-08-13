# saamsaam-infra

Everything needed to run SaamSaam on a server: compose files, env config, nginx,
and the built web assets.

## The private / public split

The stack is split across two compose files, because a server may already
provide some of it.

| File | Services | Runs when |
|---|---|---|
| `compose.yml` | `api`, `api-staging` | Always. These are ours on every host. |
| `public/compose.yml` | `nginx`, `postgres`, `redis` | Only on a host that has none of its own. |

On a box running teo-infra (or gentick-infra), `public/` stays down and the api
containers reach the existing services over `backend-net`. On a bare box, both
files come up and the stack is self-contained.

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

`.env` is built by `svc-build-env.sh` and never committed. `.env.live` and
`.env.staging` are committed overlays applied on top of it, per container.

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

**A value starting with `replace` is what marks a variable as a secret.** That
is the whole rule, so the template is the single declaration of what needs
filling — `SMTP_USER=replace@me.com` needs a cred, `LOG_LEVEL=info` is passed
through untouched. It used to look for a cred file for every variable and use
one if it happened to exist, so a stray `log_level.txt` would silently override
a setting that is not a secret.

Creds live in `/srv/data/creds`, one file per secret, named after the variable.
Case does not matter and `.txt` is optional, so all of these work for
`SMTP_USER`:

```
smtp_user.txt    SMTP_USER.txt    smtp_user    SMTP_USER
```

Two files claiming the same secret is an error, not a coin toss. So is a cred
file that still contains the placeholder text.

That directory is **flat and shared by every project on the box**, keyed on the
variable name alone. Which gives the rule that decides how to name a secret:

> **A variable's name must be unique exactly when its value must be unique.**

`POSTGRES_USER` is one database role serving several databases, so it is one
name and one file, shared. A JWT signing key is not — rms and talosot are
separate services, and one shared `api_jwt_secret` would let a token minted by
either verify against the other. So they are `API_JWT_SECRET_RMS` and
`API_JWT_SECRET_TALOSOT`: two secrets, two names, two files.

The app-suffixed form keeps the variable in its `API_*` block in `.env.example`,
and the compose file maps it to whatever the image actually reads.

Note the name must be **static**. `${PROJECT_NAME}_JWT_SECRET` does not match the
`^[A-Za-z_][A-Za-z0-9_]*=` line the template walk looks for, so it would be
passed through verbatim — and the missing-secret check only fires for lines that
matched, so the build would report success and write a live placeholder.

That directory is deliberately outside this repo and must be created by hand,
once per server, root-owned and `chmod 700`. The script writes files inside it
but will not create it.

| Invocation | Does |
|---|---|
| `./svc-build-env.sh` | Build `.env`. If creds are missing, lists them and offers to stub them. |
| `./svc-build-env.sh --defaults` | Same, but never asks — takes the yes. |
| `./svc-build-env.sh --init-creds` | Only write the stubs. Never builds `.env`. |
| `./svc-build-env.sh --check` | Report only. Writes nothing at all, not even stubs. |

A stub holds the template placeholder verbatim, so `api_jwt_secret_rms` starts
life containing `replace-me-with-a-32-byte-minimum-secret` — the shape of the
wanted value, in the file you are about to edit. It **never overwrites**, and
because the build rejects any cred still holding a placeholder, a stub cannot
turn into a silently-wrong `.env`. That rejection is what makes offering to
scaffold safe at all.

## Creating the databases

`POSTGRES_DB` is created by the postgres image on **first boot only**, and only
that one. The staging database (`POSTGRES_DB` in `.env.staging`) has to be created by
hand, once:

```bash
docker exec -it postgres psql -U saamsaam -d saamsaam -c 'CREATE DATABASE saamsaam_staging OWNER saamsaam;'
```

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
  creds/        host   secrets, read by svc-build-env.sh
  certs/        host   TLS, read by nginx
  postgres/     host   the postgres cluster — every project's databases
  redis/        host
  saamsaam/     project
```

**postgres and redis write to the host root, not the project one.** A postgres
data directory holds a whole *cluster*: `saamsaam`, `saamsaam_staging` and any
future project's databases all live in it. Filing that under one project's
folder would put project B's data inside project A's.

`PROJECT_DATA_ROOT` is for files that genuinely belong to one project — user
uploads, exports, backups. Nothing uses it yet; it is defined so the convention
exists before the first thing that needs it invents a different one.

Both are outside the repo, and outside any Windows-mounted path.

> On a Windows dev box this matters: anything under `/mnt/c/...` is DrvFs, which
> has no real `chmod`, and `initdb` refuses to run there. `/srv/data/...` from
> inside WSL is the VM's own ext4, so it works. Reach it from Windows at
> `\\wsl$\<distro>\srv\data\`.

## Domains

TLS is terminated by the Cloudflare tunnel in front of nginx, so both server
blocks listen on port 80.

| Domain | Upstream |
|---|---|
| `sm.teojordaan.com` | `saamsaam-api-staging:8080` |
| `saamsaam.archyta.com` | `saamsaam-api:8080` |

nginx addresses the api by **container** name. Compose gives a container both its
container name and its service name as network aliases, and either resolves
across compose projects — but the service name is the bare word `api`, which
would collide with any other stack on the network.

## Scripts

| Script | Purpose |
|---|---|
| `svc-build-env.sh` | Build `.env` from `.env.example` + the creds directory |
| `svc-start.sh` | Bring services up and wait for health |
| `svc-stop.sh` | Stop them |
| `svc-update.sh` | Pull new images and recreate |
| `svc-image-purge.sh` | Remove images from the local cache |
| `svc-compose.sh` | Shared helpers, sourced by the others |

The `svc-*.sh` set is **version 0.0.0**, and the canonical copies live in
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
Backend changes additionally need an image build and push to GHCR, then
`svc-update.sh`.
