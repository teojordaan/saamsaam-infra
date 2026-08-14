#!/usr/bin/env bash
# svc-scripts 0.1.1 — canonical copy: agollum/docker/services/
# Edit there and copy the whole set across; svc-compose.sh is sourced by
# the others, so a half-updated set breaks in ways that look like a bug.
# Shared helpers for the svc-*.sh scripts. Sourced, not run.
#
# Nothing here names a service. The compose file IS the service list, which is
# why the private/public split is by file rather than by an array that has to be
# kept in step with it — that array is what left svc-start.sh starting `go-api`
# months after the service was renamed.
#
# Networks are created here rather than by compose. Compose refuses to adopt a
# network it did not create ("has incorrect label com.docker.compose.network"),
# so a network declared non-external in one file cannot be pre-created for
# another. Both files declare theirs external and this owns creation, which is
# what lets --public run on its own.

SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SVC_DIR/.env}"
PRIVATE_FILE="$SVC_DIR/compose.yml"
PUBLIC_FILE="$SVC_DIR/public/compose.yml"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"

svc_files_for_scope() { # <scope> -> echoes compose files, dependency order first
  case "$1" in
    private) printf '%s\n' "$PRIVATE_FILE" ;;
    public)  printf '%s\n' "$PUBLIC_FILE" ;;
    all)     printf '%s\n%s\n' "$PUBLIC_FILE" "$PRIVATE_FILE" ;;
    *) return 1 ;;
  esac
}

svc_parse_scope() { # <args...> -> echoes the scope if --scope was given, else empty
  # Empty, not "private": svc_resolve_scope decides between prompting a human and
  # taking the default, and once a default is baked in here it can no longer tell
  # "no --scope given" from an explicit "--scope private".
  local scope=""
  while (( $# )); do
    case "$1" in
      --scope)
        [[ $# -ge 2 ]] || { printf -- '--scope needs a value (private|public|all)\n' >&2; return 1; }
        case "$2" in
          private|public|all) scope="$2" ;;
          *) printf 'unknown scope: %s (expected private, public or all)\n' "$2" >&2; return 1 ;;
        esac
        shift ;;
      # Accepted so "always pass --defaults" holds for every agollum script.
      # svc_resolve_scope reads it separately to mean "do not prompt, take the
      # default" — the same job it does in svc-image-purge.sh and svc-build-env.sh.
      --defaults) ;;
      *) printf 'unknown argument: %s (expected --scope private|public|all)\n' "$1" >&2
         return 1 ;;
    esac
    shift
  done
  printf '%s' "$scope"
}

svc_has_flag() { # <flag> <args...> -> 0 if <flag> appears among the args
  local want="$1"; shift
  local a
  for a in "$@"; do [[ "$a" == "$want" ]] && return 0; done
  return 1
}

# The interactive scope menu for the start/stop/update trio. svc-image-purge.sh
# keeps its own: its scopes differ (host, not all) and it has no default because
# it destroys things. Here private is the documented default, so an empty answer
# takes it. Menu and prompt go to stderr; only the chosen scope reaches stdout,
# so `scope=$(svc_prompt_scope)` captures the answer and nothing else.
svc_prompt_scope() { # -> echoes private|public|all, or fails on a bad choice
  local choice
  {
    printf 'Which services?\n'
    printf '  1) private  this app only (compose.yml)            [default]\n'
    printf '  2) public   backing services (public/compose.yml): nginx, db, redis\n'
    printf '  3) all      public first, then private\n'
  } >&2
  read -rp 'Choice [1-3, Enter=private]: ' choice
  case "$choice" in
    ''|1|private) printf 'private' ;;
    2|public)     printf 'public'  ;;
    3|all)        printf 'all'     ;;
    *) printf 'invalid choice: %s\n' "$choice" >&2; return 1 ;;
  esac
}

# Resolve the scope for svc-start/stop/update. An explicit --scope wins. Failing
# that, a human at a terminal is asked; every non-interactive caller — --defaults,
# cron, a pipe, svc-update called from a script — takes the documented default,
# private. Validates its args first, so a typo fails rather than silently
# dropping into the prompt. Echoes the scope; returns 2 on any misuse, matching
# the house rule that bad usage exits 2.
svc_resolve_scope() { # <args...> -> echoes private|public|all
  local scope
  scope="$(svc_parse_scope "$@")" || return 2
  if [[ -n "$scope" ]]; then printf '%s' "$scope"; return 0; fi
  if [[ -t 0 ]] && ! svc_has_flag --defaults "$@"; then
    svc_prompt_scope || return 2
  else
    printf 'private'
  fi
}

compose() { # <file> <args...>
  local file="$1"; shift
  docker compose --env-file "$ENV_FILE" -f "$file" "$@"
}

# External networks this stack joins but does not own. Read from the resolved
# compose config so the names come from one place rather than being re-derived
# by parsing .env, where ${PROJECT_NAME} would need expanding by hand.
svc_external_networks() { # <file>
  compose "$1" config 2>/dev/null | awk '
    /^networks:/            { inn=1; next }
    /^[^ ]/                 { inn=0 }
    inn && /^  [^ ]/        { name="" }
    inn && /^    name: /    { name=$2 }
    inn && /^    external: true/ { if (name != "") print name }
  '
}

svc_ensure_networks() { # <file>
  local net
  while read -r net; do
    [[ -n "$net" ]] || continue
    docker network inspect "$net" >/dev/null 2>&1 && continue
    svc_log "creating network $net"
    docker network create "$net" >/dev/null || return 1
  done < <(svc_external_networks "$1")
}

svc_wait_healthy() { # <file> — every container in that file, or fail
  local file="$1" deadline cids cid name state hs bad starting ok total reasons r
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))

  while :; do
    mapfile -t cids < <(compose "$file" ps -q)
    (( ${#cids[@]} )) || { svc_err "no containers running for $(basename "$(dirname "$file")")/$(basename "$file")"; return 1; }

    bad=0; starting=0; ok=0; total=${#cids[@]}; reasons=()
    for cid in "${cids[@]}"; do
      name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
      state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
      hs=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)

      case "$state" in
        running) ;;
        restarting) starting=$((starting+1)); reasons+=("${name}: restarting"); continue ;;
        *) bad=$((bad+1)); reasons+=("${name}: ${state}"); continue ;;
      esac
      case "$hs" in
        healthy|none) ok=$((ok+1)) ;;
        unhealthy)    bad=$((bad+1)); reasons+=("${name}: unhealthy") ;;
        *)            starting=$((starting+1)) ;;
      esac
    done

    if (( bad > 0 )); then
      for r in "${reasons[@]}"; do svc_err "$r"; done
      compose "$file" ps
      return 1
    fi
    (( ok == total )) && { svc_log "${ok}/${total} healthy"; return 0; }

    if (( $(date +%s) >= deadline )); then
      for r in "${reasons[@]}"; do svc_err "$r"; done
      compose "$file" ps
      svc_err "timed out after ${HEALTH_TIMEOUT}s (${starting} still starting)"
      return 1
    fi
    sleep "$HEALTH_INTERVAL"
  done
}
