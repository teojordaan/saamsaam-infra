#!/usr/bin/env bash
# svc-scripts 0.1.1 — canonical copy: agollum/docker/services/
# Edit there and copy the whole set across; svc-compose.sh is sourced by
# the others, so a half-updated set breaks in ways that look like a bug.
# Bring the stack down.
#
#   --scope private   compose.yml         — always ours (default)
#   --scope public    public/compose.yml  — only where the host provides none
#   --scope all       private first, then public
#   --defaults        take the default (private) without prompting
#
# With no --scope on an interactive terminal it asks which to stop; piped, in
# cron, or under --defaults it takes private. See svc_resolve_scope.
#
# --scope all stops in the reverse order of svc-start.sh, so the things that depend
# on postgres are gone before postgres is.
#
# Networks are left alone. They are declared external and created by
# svc-start.sh, and another stack may be sitting on them.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
svc_log() { printf '[stop] %s\n' "$*"; }
svc_err() { printf '[stop] %s\n' "$*" >&2; }
die()     { printf '[stop] FATAL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=svc-compose.sh
source "$SCRIPT_DIR/svc-compose.sh" || die "svc-compose.sh not found"

case "${1:-}" in
  -h|--help) awk 'NR>4 && /^#/ { sub(/^# ?/,""); print; next } NR>4 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

SCOPE="$(svc_resolve_scope "$@")" || exit 2

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found"

# Reverse svc-start.sh's order for --all.
mapfile -t FILES < <(svc_files_for_scope "$SCOPE")
for (( i=${#FILES[@]}-1; i>=0; i-- )); do
  file="${FILES[$i]}"
  [[ -f "$file" ]] || die "$file not found"
  svc_log "stopping $(basename "$(dirname "$file")")"
  compose "$file" down --remove-orphans || die "compose down failed for $file"
done

svc_log "DONE — scope=$SCOPE"
