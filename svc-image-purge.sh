#!/usr/bin/env bash
# svc-scripts 0.1.0 — canonical copy: agollum/docker/services/
# Edit there and copy the whole set across; svc-compose.sh is sourced by
# the others, so a half-updated set breaks in ways that look like a bug.
# Remove images from this machine's docker cache.
#
#   --scope private   every tag of every image named in compose.yml
#   --scope public    every tag of every image named in public/compose.yml
#   --scope host      EVERY image on this machine, including other projects'
#   --dry-run         list what would go, remove nothing
#   --yes             skip the confirmation (host scope always confirms)
#
# private and public mean the same thing here as in svc-start.sh: a compose
# file. They used to mean a registry — ghcr.io vs Docker Hub — which happened
# to select the same images only because compose.yml holds the ghcr one. The
# day that stopped being true, the same word would have purged the other half.
#
# ALL tags go, not just the one the compose file currently names. Reclaiming
# space is the whole point, and the old tags are what take it up. An image
# backing an existing container is skipped and reported rather than forced:
# untagging it out from under a container leaves something that cannot be
# restarted without a pull.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
svc_log() { printf '[purge] %s\n' "$*"; }
svc_err() { printf '[purge] %s\n' "$*" >&2; }
die()     { printf '[purge] FATAL: %s\n' "$*" >&2; exit 1; }
usage()   { printf '[purge] FATAL: %s\n' "$*" >&2; exit 2; }

# shellcheck source=svc-compose.sh
source "$SCRIPT_DIR/svc-compose.sh" || die "svc-compose.sh not found"

SCOPE=""
DRY_RUN=false
ASSUME_YES=false
NONINTERACTIVE=false
while (( $# )); do
  case "$1" in
    --scope)
      [[ $# -ge 2 ]] || usage "--scope needs a value (private|public|host)"
      case "$2" in
        private|public|host) SCOPE="$2" ;;
        *) usage "unknown scope: $2 (use private|public|host)" ;;
      esac
      shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y)  ASSUME_YES=true; shift ;;
    # --defaults is the house flag for "do not prompt". There is deliberately no
    # default scope: this removes images, so the one decision that matters is
    # never guessed. Missing --scope under --defaults is a usage error, not a
    # prompt and not a guess.
    --defaults) ASSUME_YES=true; NONINTERACTIVE=true; shift ;;
    -h|--help) awk 'NR>4 && /^#/ { sub(/^# ?/,""); print; next } NR>4 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) usage "unknown argument: $1" ;;
  esac
done

if [[ -z "$SCOPE" ]] && { $NONINTERACTIVE || [[ ! -t 0 ]]; }; then
  usage "--scope is required when not interactive (private|public|host)"
fi

if [[ -z "$SCOPE" ]]; then
  echo "Which images should go?"
  echo "  1) private  — every tag of the images in compose.yml"
  echo "  2) public   — every tag of the images in public/compose.yml"
  echo "  3) host     — EVERY image on this machine, including other projects'"
  read -rp "Choice [1-3]: " choice
  case "$choice" in
    1|private) SCOPE="private" ;;
    2|public)  SCOPE="public"  ;;
    3|host)    SCOPE="host"    ;;
    *) die "invalid choice: $choice" ;;
  esac
fi

# Repositories (image refs with the tag stripped) named by a compose file.
#
# compose's own error is passed through on failure. The usual cause is a missing
# .env — compose.yml needs one for its env_file — and a generic "no images
# found" sends you looking at docker instead of at the file that is absent.
repos_in() { # <file>
  local out rc
  out="$(compose "$1" config 2>&1)"; rc=$?
  if (( rc != 0 )); then
    svc_err "docker compose could not read $1:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  printf '%s\n' "$out" \
    | awk '/^ +image: /{print $2}' \
    | sed 's/@sha256:.*//; s/:[^:/]*$//' \
    | sort -u
}

# Every local tag belonging to those repositories.
mapfile -t LOCAL < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '^<none>:<none>$' | sort -u)
(( ${#LOCAL[@]} )) || { svc_log "no images on this machine — nothing to do"; exit 0; }

TARGETS=()
case "$SCOPE" in
  host)
    TARGETS=("${LOCAL[@]}")
    ;;
  private|public)
    [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found — run ./svc-build-env.sh first"
    file="$PRIVATE_FILE"; [[ "$SCOPE" == "public" ]] && file="$PUBLIC_FILE"
    [[ -f "$file" ]] || die "$file not found"
    mapfile -t REPOS < <(repos_in "$file") || die "could not read $file"
    (( ${#REPOS[@]} )) || die "no images resolved from $file"
    svc_log "repositories in $(basename "$(dirname "$file")")/$(basename "$file"): ${REPOS[*]}"
    for img in "${LOCAL[@]}"; do
      for r in "${REPOS[@]}"; do
        [[ "${img%:*}" == "$r" ]] && { TARGETS+=("$img"); break; }
      done
    done
    ;;
esac

(( ${#TARGETS[@]} )) || { svc_log "nothing matches scope '$SCOPE'"; exit 0; }

# Images backing a container (running or not) are skipped, not forced.
mapfile -t IN_USE < <(docker ps -a --format '{{.Image}}' 2>/dev/null | sort -u)
in_use() {
  local img="$1" u
  for u in "${IN_USE[@]:-}"; do [[ "$u" == "$img" ]] && return 0; done
  return 1
}

REMOVE=(); SKIP=()
for img in "${TARGETS[@]}"; do
  if in_use "$img"; then SKIP+=("$img"); else REMOVE+=("$img"); fi
done

if (( ${#SKIP[@]} )); then
  svc_log "skipping ${#SKIP[@]} image(s) backing a container:"
  for img in "${SKIP[@]}"; do svc_log "  $img"; done
fi

if (( ${#REMOVE[@]} == 0 )); then
  svc_log "everything in scope '$SCOPE' is in use — nothing removed"
  exit 0
fi

svc_log "${#REMOVE[@]} image(s) to remove (scope: $SCOPE):"
for img in "${REMOVE[@]}"; do svc_log "  $img"; done

if $DRY_RUN; then
  svc_log "--dry-run — nothing removed"
  exit 0
fi

if ! $ASSUME_YES || [[ "$SCOPE" == "host" ]]; then
  [[ "$SCOPE" == "host" ]] && svc_err "host scope removes images belonging to every project on this machine."
  read -rp "Remove these ${#REMOVE[@]} image(s)? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY] ]] || die "cancelled"
fi

failed=0
for img in "${REMOVE[@]}"; do
  if docker image rm "$img" >/dev/null 2>&1; then
    svc_log "  removed $img"
  else
    svc_err "  could not remove $img"
    failed=$((failed+1))
  fi
done

(( failed == 0 )) || die "$failed image(s) could not be removed"
svc_log "DONE — scope=$SCOPE"
