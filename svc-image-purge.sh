#!/usr/bin/env bash
# ============================================================
# SaamSaam — purge Docker images from the local cache.
#
# Supports interactive (human) and non-interactive (agentic)
# modes. When args are provided, runs without prompting.
#
# Usage:  svc-image-purge.sh [--scope all|private|public]
#
#   --scope all       — remove ALL Docker images
#   --scope private   — remove only GHCR-hosted images (ghcr.io/*)
#   --scope public    — remove only Docker Hub images (docker.io/*)
#
# With no arguments, prompts interactively.
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() { printf '[purge] %s\n' "$*"; }
die() { printf '[purge] FATAL: %s\n' "$*" >&2; exit 1; }

# ── Parse args ────────────────────────────────────────────
SCOPE=""
while (( $# )); do
  case "$1" in
    --scope)
      [[ $# -ge 2 ]] || die "--scope needs a value (all|private|public)"
      case "$2" in
        all|private|public) SCOPE="$2" ;;
        *) die "unknown scope: $2 (use all|private|public)" ;;
      esac
      shift 2
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--scope all|private|public]"
      exit 0
      ;;
    *) die "unknown argument: $1 (use --scope all|private|public)" ;;
  esac
done

# ── Interactive prompt (if no args) ───────────────────────
if [[ -z "$SCOPE" ]]; then
  echo "Which images would you like to remove?"
  echo "  1) all      — remove ALL Docker images"
  echo "  2) private  — remove only GHCR images (ghcr.io/*)"
  echo "  3) public   — remove only Docker Hub images (docker.io/*)"
  read -rp "Choice [1-3]: " choice
  case "$choice" in
    1|all)      SCOPE="all" ;;
    2|private)  SCOPE="private" ;;
    3|public)   SCOPE="public" ;;
    *) die "invalid choice: $choice" ;;
  esac

  echo ""
  echo "WARNING: This will remove selected Docker images from the local cache."
  read -rp "Are you sure? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY] ]] || die "Cancelled."
fi

# ── Get all images ────────────────────────────────────────
ALL_IMAGES="$(
  docker images --format '{{.Repository}}:{{.Tag}}@{{.ID}}' 2>/dev/null \
    | grep -v '<none>:<none>'
)"

if [[ -z "$ALL_IMAGES" ]]; then
  log "No Docker images found — nothing to purge."
  exit 0
fi

# ── Filter by scope ──────────────────────────────────────
case "$SCOPE" in
  all)
    mapfile -t TO_REMOVE < <(docker images -q 2>/dev/null | sort -u)
    ;;
  private)
    mapfile -t TO_REMOVE < <(
      docker images --format '{{.Repository}}@{{.ID}}' 2>/dev/null \
        | grep -i '^ghcr\.io/' \
        | sed 's/.*@//' \
        | sort -u
    )
    ;;
  public)
    mapfile -t TO_REMOVE < <(
      docker images --format '{{.Repository}}@{{.ID}}' 2>/dev/null \
        | grep -vi '^ghcr\.io/' \
        | sed 's/.*@//' \
        | sort -u
    )
    ;;
esac

if [[ ${#TO_REMOVE[@]} -eq 0 ]]; then
  log "No images match scope '${SCOPE}' — nothing to purge."
  exit 0
fi

# ── Remove ────────────────────────────────────────────────
log "Removing ${#TO_REMOVE[@]} image(s) (scope: ${SCOPE})..."
for id in "${TO_REMOVE[@]}"; do
  if docker rmi -f "$id" >/dev/null 2>&1; then
    log "  removed ${id}"
  fi
done

log "DONE — purge complete (scope: ${SCOPE})"
exit 0
