#!/usr/bin/env bash
# Bring the SaamSaam stack up, or just the part of it this host needs.
# ============================================================
# SaamSaam — bring the compose stack up.
#
# Idempotent: only creates/updates containers as needed. Leaves existing
# (healthy) containers running. To force-recreate one:
#   docker compose up -d --force-recreate go-api
#
# Service groups
# --------------
#   private   go-api, go-api-staging      — always ours
#   public    postgres, redis, nginx      — only when the host has none
#   all       everything
#
# The whole point of the split is that this repo can deploy the stack on ANY
# server. A bare box runs `--all`. A box already running teo-infra (or
# gentick-infra) runs `--private`, because postgres, redis and nginx are
# already there and a second set would fight the first for ports and names.
#
# !! --private passes --no-deps, and it has to. go-api declares
# !! `depends_on: postgres` so a standalone bring-up orders correctly — but
# !! without --no-deps, `compose up go-api` starts postgres too, which is
# !! precisely the second database the split exists to avoid. The failure is
# !! quiet: the api talks to whichever container won the name on backend-net.
#
# Default scope is `private`, matching the hosts we actually deploy to.
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/compose.yml}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"

cd "$SCRIPT_DIR"

log() { printf '[start] %s\n' "$*"; }
die() { printf '[start] FATAL: %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]]     || die "$ENV_FILE not found"
[[ -f "$COMPOSE_FILE" ]] || die "$COMPOSE_FILE not found"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"

# ---- service groups (edit these to change what each scope starts) ----
# Names must match the service keys in compose.yml.
PRIVATE_SVCS=(go-api go-api-staging)
PUBLIC_SVCS=(postgres redis nginx)
ALL_SVCS=(postgres redis go-api go-api-staging nginx)

SCOPE="private"
while (( $# )); do
  case "$1" in
    --private) SCOPE="private" ;;
    --public)  SCOPE="public"  ;;
    --all)     SCOPE="all"     ;;
    -h|--help)
      sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $1 (expected --private, --public or --all)" ;;
  esac
  shift
done

case "$SCOPE" in
  private) SVCS=("${PRIVATE_SVCS[@]}"); NO_DEPS=(--no-deps) ;;
  public)  SVCS=("${PUBLIC_SVCS[@]}");  NO_DEPS=(--no-deps) ;;
  all)     SVCS=("${ALL_SVCS[@]}");     NO_DEPS=() ;;
esac

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

# backend-net is external — this stack joins it, never creates it. Without a
# shared-infra stack running there is nothing to create it, and compose fails
# with an error that reads like a typo rather than a missing prerequisite.
SHARED_NET_NAME="$(grep -E '^SHARED_NET=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)"
SHARED_NET_NAME="${SHARED_NET_NAME:-backend-net}"
if ! docker network inspect "$SHARED_NET_NAME" >/dev/null 2>&1; then
  log "shared network '$SHARED_NET_NAME' does not exist — creating it"
  docker network create "$SHARED_NET_NAME" >/dev/null || die "could not create $SHARED_NET_NAME"
fi

log "scope=$SCOPE — starting: ${SVCS[*]}"
if ! compose up -d "${NO_DEPS[@]}" "${SVCS[@]}"; then
  die "compose up failed"
fi

log "Waiting up to ${HEALTH_TIMEOUT}s for containers to become healthy"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))

while :; do
  mapfile -t cids < <(compose ps -q "${SVCS[@]}")
  if [[ ${#cids[@]} -eq 0 ]]; then
    die "no containers running after compose up"
  fi

  bad=0; starting=0; ok=0; total=${#cids[@]}
  reasons=()

  for cid in "${cids[@]}"; do
    name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
    state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
    hs=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)

    case "$state" in
      running) : ;;
      restarting) starting=$((starting+1)); reasons+=("${name}: restarting"); continue ;;
      *) bad=$((bad+1)); reasons+=("${name}: ${state}"); continue ;;
    esac

    case "$hs" in
      healthy|none) ok=$((ok+1));;
      starting)     starting=$((starting+1));;
      unhealthy)    bad=$((bad+1)); reasons+=("${name}: unhealthy");;
      *)            starting=$((starting+1));;
    esac
  done

  if (( bad > 0 )); then
    for r in "${reasons[@]}"; do log "$r"; done
    compose ps
    die "one or more services are not healthy"
  fi

  if (( ok == total )); then
    log "DONE — ${ok}/${total} containers healthy"
    exit 0
  fi

  if (( $(date +%s) >= deadline )); then
    for r in "${reasons[@]}"; do log "$r"; done
    compose ps
    die "timed out waiting for healthy (${starting} still starting)"
  fi

  sleep "$HEALTH_INTERVAL"
done
