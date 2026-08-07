#!/usr/bin/env bash
# ============================================================
# SaamSaam — pull images defined in compose.yml.
#
# Image tags are now hardcoded in compose.yml (not in
# .env). This script reads them from the compose file so there's
# no duplication — bump the tag in one place.
#
# --force / -f <scope> — delete local copies before pulling so
# an in-place rebuild at the SAME version tag lands.
# Scopes: private (ghcr.io images), public (docker hub), all.
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/compose.yml}"
cd "$SCRIPT_DIR"

log() { printf '[update] %s\n' "$*"; }
die() { printf '[update] FATAL: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------
# GHCR credentials — source from .env (built by build-env.py)
# ------------------------------------------------------------
GHCR_REGISTRY="ghcr.io"

if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

GHCR_USER="${GHCR_USER:-}"
GHCR_PAT="${GHCR_PAT:-}"

# ------------------------------------------------------------
# Parse image refs from the compose file (the one source of truth)
# ------------------------------------------------------------
# We use `docker compose config` so Docker's YAML parser does the work.
# Image tags are now hardcoded in the compose file, so no env vars
# are needed to resolve them — but we still pass --env-file in case
# other compose-level vars (ports, volumes) need values.
COMPOSE_CMD=(docker compose -f "$COMPOSE_FILE")
[[ -f "$ENV_FILE" ]] && COMPOSE_CMD+=(--env-file "$ENV_FILE")

mapfile -t ALL_IMAGES < <("${COMPOSE_CMD[@]}" config 2>/dev/null \
  | grep -E '^\s+image:\s+' | sed 's/.*image:\s*//' | sort -u)

if [[ ${#ALL_IMAGES[@]} -eq 0 ]]; then
  die "no image: lines found in compose config — is Docker running?"
fi

# Classify by registry
PRIVATE_IMAGES=()
PUBLIC_IMAGES=()
for img in "${ALL_IMAGES[@]}"; do
  if [[ "$img" == ghcr.io/* ]]; then
    PRIVATE_IMAGES+=("$img")
  else
    PUBLIC_IMAGES+=("$img")
  fi
done

log "Images to pull: ${ALL_IMAGES[*]}"

# ------------------------------------------------------------
# Parse --force scope
# ------------------------------------------------------------
FORCE_SCOPE=""
usage() {
  cat <<EOF
Usage: $(basename "$0") [--force|-f private|public|all]

  --force private   delete local ghcr.io images before pulling
  --force public    delete local Docker Hub images before pulling
  --force all       delete everything before pulling
EOF
}
while (( $# )); do
  case "$1" in
    -f|--force)
      [[ $# -ge 2 ]] || { usage; die "--force needs a scope (private|public|all)"; }
      case "$2" in
        private|public|all) FORCE_SCOPE="$2" ;;
        *) usage; die "unknown --force scope: $2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

# ------------------------------------------------------------
# 1) Log in to GHCR
# ------------------------------------------------------------
if [[ -n "$GHCR_PAT" ]]; then
  log "Logging in to ${GHCR_REGISTRY}"
  if ! printf '%s' "$GHCR_PAT" | docker login "$GHCR_REGISTRY" -u "$GHCR_USER" --password-stdin >/dev/null 2>&1; then
    die "docker login to ${GHCR_REGISTRY} failed"
  fi
  log "Registry login OK"
else
  log "No GHCR_PAT set — skipping private registry login (public images only)"
fi

# ------------------------------------------------------------
# 2) --force: nuke local copies
# ------------------------------------------------------------
if [[ -n "$FORCE_SCOPE" ]]; then
  case "$FORCE_SCOPE" in
    private) TO_REMOVE=( "${PRIVATE_IMAGES[@]}" ) ;;
    public)  TO_REMOVE=( "${PUBLIC_IMAGES[@]}"  ) ;;
    all)     TO_REMOVE=( "${ALL_IMAGES[@]}"     ) ;;
  esac
  log "force scope: ${FORCE_SCOPE} — removing ${#TO_REMOVE[@]} local image(s)"
  for ref in "${TO_REMOVE[@]}"; do
    [[ -n "$ref" ]] || continue
    if docker image rm -f "$ref" >/dev/null 2>&1; then
      log "  removed ${ref}"
    else
      log "  not cached: ${ref}"
    fi
  done
fi

# ------------------------------------------------------------
# 3) Pull via docker compose (reads image refs from compose file)
# ------------------------------------------------------------
log "Pulling images via docker compose..."
if ! "${COMPOSE_CMD[@]}" pull; then
  die "docker compose pull failed"
fi

log "DONE — all images present"
exit 0
