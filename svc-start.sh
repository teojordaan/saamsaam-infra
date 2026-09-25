#!/usr/bin/env bash
# svc-scripts 0.1.2 — canonical copy: agollum/docker/services/
# Edit there and copy the whole set across; svc-compose.sh is sourced by
# the others, so a half-updated set breaks in ways that look like a bug.
# Bring the stack up, or the part of it this host needs.
#
#   --scope private   compose.yml         — always ours (default)
#   --scope public    public/compose.yml  — only where the host provides none
#   --scope all       public first, healthy, then private
#   --defaults        take the default (private) without prompting
#
# With no --scope on an interactive terminal it asks which to start; piped, in
# cron, or under --defaults it takes private. See svc_resolve_scope.
#
# Idempotent: leaves healthy containers alone. Force one to rebuild with
#   docker compose --env-file .env -f compose.yml up -d --force-recreate api
#
# --scope all waits for public to be healthy before starting private. The compose
# files carry no depends_on because every dependency they could express crosses
# the private/public line, and `compose up` on one side would then silently
# start the other — a second database, which is what the split exists to
# prevent. The ordering lives here instead.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
svc_log() { printf '[start] %s\n' "$*"; }
svc_err() { printf '[start] %s\n' "$*" >&2; }
die()     { printf '[start] FATAL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=svc-compose.sh
source "$SCRIPT_DIR/svc-compose.sh" || die "svc-compose.sh not found"

case "${1:-}" in
  -h|--help) awk 'NR>4 && /^#/ { sub(/^# ?/,""); print; next } NR>4 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

SCOPE="$(svc_resolve_scope "$@")" || exit 2

[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found — run ./svc-build-env.sh first"

# Render a broker's generated config (nanomq pwd/ACL) from .env BEFORE bringing
# services up -- but ONLY in a repo that carries the generator. A stack with no
# broker does not ship svc-gen-nanomq.sh at all, so this is skipped outright
# rather than running a no-op that reports on a broker the stack never had.
#
# Where the generator IS present the call stays automatic, deliberately. The
# files it writes are gitignored, so on a fresh clone they do not exist, and a
# broker started before them has docker bind-mount an empty DIRECTORY over each
# missing file. nanomq then crash-loops with "input in flex scanner failed" --
# three levels down in `docker logs`, reading as a broken image. Generating
# first is what prevents that, and it has to happen on every bring-up rather
# than whenever someone remembers.
#
# Invoked through `bash` rather than executed directly: the mode bit does not
# survive every checkout (a copy committed from Windows lands 644), and a
# generator that is present but not executable must not take the whole bring-up
# down with "Permission denied".
if [[ -f "$SCRIPT_DIR/svc-gen-nanomq.sh" ]]; then
  ENV_FILE="$ENV_FILE" bash "$SCRIPT_DIR/svc-gen-nanomq.sh" || die "broker config generation failed"
fi

while read -r file; do
  [[ -f "$file" ]] || die "$file not found"
  label="$(basename "$(dirname "$file")")"

  svc_ensure_networks "$file" || die "could not create the networks $label needs"

  svc_log "starting $label"
  compose "$file" up -d || die "compose up failed for $file"

  svc_log "waiting up to ${HEALTH_TIMEOUT}s for $label to become healthy"
  svc_wait_healthy "$file" || die "$label is not healthy"
done < <(svc_files_for_scope "$SCOPE")

svc_log "DONE — scope=$SCOPE"
