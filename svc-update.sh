#!/usr/bin/env bash
# svc-scripts 0.1.0 — canonical copy: agollum/docker/services/
# Edit there and copy the whole set across; svc-compose.sh is sourced by
# the others, so a half-updated set breaks in ways that look like a bug.
# Pull the images the compose files name, then recreate.
#
#   --scope private   compose.yml         — always ours (default)
#   --scope public    public/compose.yml  — only where the host provides none
#   --scope all       both
#   --force           remove local copies first, so an in-place rebuild at the
#                     SAME version tag actually lands
#
# Image tags live in the compose files, so this reads them from there rather
# than keeping its own list.
#
# Registry credentials are NOT handled here. Run `docker login ghcr.io` once per
# host and docker keeps the credential. A PAT in .env would sit in plaintext on
# every box holding a copy of this repo, in the first file anyone would open.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
svc_log() { printf '[update] %s\n' "$*"; }
svc_err() { printf '[update] %s\n' "$*" >&2; }
die()     { printf '[update] FATAL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=svc-compose.sh
source "$SCRIPT_DIR/svc-compose.sh" || die "svc-compose.sh not found"

GHCR_REGISTRY="ghcr.io"
FORCE=false
ARGS=()
for a in "$@"; do
  case "$a" in
    --force|-f) FORCE=true ;;
    -h|--help)  awk 'NR>4 && /^#/ { sub(/^# ?/,""); print; next } NR>4 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done

SCOPE="$(svc_parse_scope "${ARGS[@]+"${ARGS[@]}"}")" || exit 2
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found — run ./svc-build-env.sh first"

images_in() { # <file> — compose's own error passed through on failure
  local out rc
  out="$(compose "$1" config 2>&1)"; rc=$?
  if (( rc != 0 )); then
    svc_err "docker compose could not read $1:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return 1
  fi
  printf '%s\n' "$out" | awk '/^ +image: /{print $2}' | sort -u
}

private_registry_used=false

while read -r file; do
  [[ -f "$file" ]] || die "$file not found"
  label="$(basename "$(dirname "$file")")"

  mapfile -t IMAGES < <(images_in "$file") || die "could not read $file"
  (( ${#IMAGES[@]} )) || die "no images resolved from $file"
  for img in "${IMAGES[@]}"; do
    [[ "$img" == "$GHCR_REGISTRY"/* ]] && private_registry_used=true
  done

  svc_log "$label images: ${IMAGES[*]}"

  if $FORCE; then
    for img in "${IMAGES[@]}"; do
      if docker image rm -f "$img" >/dev/null 2>&1; then
        svc_log "  removed $img"
      else
        svc_log "  not cached: $img"
      fi
    done
  fi

  svc_log "pulling $label"
  if ! compose "$file" pull; then
    if $private_registry_used; then
      svc_err ""
      svc_err "If that was an authentication error, this host is not logged in"
      svc_err "to ${GHCR_REGISTRY}. Do it once, by hand:"
      svc_err ""
      svc_err "    docker login ${GHCR_REGISTRY}"
      svc_err ""
    fi
    die "pull failed for $file"
  fi

  svc_log "recreating $label"
  compose "$file" up -d || die "compose up failed for $file"
  svc_wait_healthy "$file" || die "$label is not healthy after update"
done < <(svc_files_for_scope "$SCOPE")

svc_log "DONE — scope=$SCOPE"
