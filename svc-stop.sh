#!/usr/bin/env bash
# ============================================================
# SaamSaam — bring the docker-compose stack down.
#
# Usage:  svc-stop.sh [scope]
#
#   scope      what to stop (default: all)
#     all       stop and remove all services (containers, networks)
#     private   stop only app images (go-api, nginx)
#     public    stop only infrastructure (postgres, redis)
#
# Examples:
#   svc-stop.sh              # stop everything
#   svc-stop.sh all          # same as default
#   svc-stop.sh private      # stop only go-api + nginx
#   svc-stop.sh public       # stop only postgres + redis
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/compose.yml}"

cd "$SCRIPT_DIR"

SCOPE="${1:-all}"

log() { printf '[stop] %s\n' "$*"; }
die() { printf '[stop] FATAL: %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]]     || die "$ENV_FILE not found"
[[ -f "$COMPOSE_FILE" ]] || die "$COMPOSE_FILE not found"

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

case "$SCOPE" in
  all)
    log "Stopping ALL services"
    compose down --remove-orphans
    log "All services stopped"
    ;;

  private)
    log "Stopping private services (go-api, nginx)..."
    compose stop go-api nginx
    compose rm -f go-api nginx 2>/dev/null || true
    log "Private services stopped"
    ;;

  public)
    log "Stopping public services (postgres, redis)..."
    compose stop postgres redis
    compose rm -f postgres redis 2>/dev/null || true
    log "Public services stopped"
    ;;

  *)
    die "Unknown scope: $SCOPE (use: all, private, public)"
    ;;
esac
