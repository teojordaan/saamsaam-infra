#!/usr/bin/env bash
# svc-scripts 0.1.0 — canonical copy: agollum/docker/services/
# Edit there and copy the whole set across; svc-compose.sh is sourced by
# the others, so a half-updated set breaks in ways that look like a bug.
# ============================================================
# Build .env from .env.example, filling secrets from the pragma file.
#
#   ./svc-build-env.sh                # build; offer to stub whatever is missing
#   ./svc-build-env.sh --defaults     # same, but never prompt (takes the yes)
#   ./svc-build-env.sh --init-pragma  # only append the stubs, never build .env
#   ./svc-build-env.sh --check        # report only, write nothing at all
#
# Shell rather than Python so it runs on any server without asking
# what interpreters are installed.
#
# ── What counts as a secret ──────────────────────────────────
#
# Any value in the template starting with "replace". That is the
# whole rule, and the template is therefore the single declaration
# of what needs filling:
#
#   SMTP_USER=replace@me.com        -> needs a secret
#   LOG_LEVEL=info                  -> passed through untouched
#
# It used to look for a value for EVERY variable and use one if it
# happened to exist, so a stray LOG_LEVEL entry would silently
# override a setting that is not a secret.
#
# ── The pragma file ──────────────────────────────────────────
#
# ONE file, at ONE fixed path, KEY=value per line, holding every
# secret on the box:
#
#   /srv/data/pragma
#
# The path is not configurable, and deliberately does not follow
# HOST_DATA_ROOT. That variable exists to move BULK data onto an
# external drive; secrets are a few kilobytes and never grow. Coupling
# them meant compose and this script could disagree about where the
# data root was, on exactly the hosts where it mattered.
#
#   # comments and blank lines are ignored
#   POSTGRES_USER=gentick
#   POSTGRES_PASSWORD=s3cr3t
#   API_JWT_SECRET_RMS=0f3a...
#
# This replaced a directory of one-file-per-secret in 0.1.0. That
# shape was easier to parse and worse to live with: standing up a box
# meant opening eight files in nano to set eight values. One file is
# one edit, and the whole credential state of the machine is visible
# at a glance. There is NO fallback to the old directory — see
# "Migrating from a creds directory" below.
#
# It is FLAT and shared by every project on the box, keyed on the
# variable name alone. So a variable's name must be unique exactly
# when its value must be unique: POSTGRES_USER is one database role
# and therefore one key, while API_JWT_SECRET_RMS and
# API_JWT_SECRET_TALOSOT are two signing keys and therefore two.
# Giving two different secrets one name is how two services end up
# able to forge each other's tokens.
#
# The file is not in this repo and cannot be — it must be placed by
# hand once per server, OWNED BY THE DEPLOY USER and chmod 600. This
# script appends to it, but will not create it.
#
# Not root-owned: this script runs as whoever deploys, so a root-owned
# file is Permission denied on the read. Running the whole script under
# sudo does not fix it — that writes a root-owned .env, which docker
# compose then cannot read as the deploy user. Mode 600 keeps every
# other unprivileged account out either way.
#
# ── Parsing rules, and why each one is there ─────────────────
#
#   KEY=value        split on the FIRST '=' only. Base64 values end
#                    in '=' or '==', and splitting on the last one
#                    would silently truncate every one of them.
#   # comment        only at the START of a line. A '#' mid-value is
#                    a perfectly ordinary password character.
#   blank lines      ignored.
#   whitespace       trimmed from both ends of the value.
#   "quoted value"   one matching pair of surrounding quotes is
#                    stripped, single or double. People add them out
#                    of habit, and it is also the only way to express
#                    a value with meaningful leading or trailing
#                    whitespace.
#   CR and BOM       stripped. The file gets edited from Windows.
#
# A duplicate key is an error, not last-wins. So is a line that is
# none of the above: a typo like "POSTGRES PASSWORD=x" would
# otherwise be silently ignored and surface later as a login failure.
#
# Multi-line secrets (a PEM key, a certificate) do NOT belong here —
# they cannot be expressed as KEY=value. Keep them as files, next to
# the other certificates.
#
# ── Migrating from a creds directory ─────────────────────────
#
# Run ONCE per server, then check the result before deleting anything:
#
#   for f in /srv/data/creds/*; do
#     [ -f "$f" ] || continue
#     k=$(basename "$f"); k=${k%.txt}
#     printf '%s=%s\n' "$(printf '%s' "$k" | tr 'a-z' 'A-Z')" "$(head -1 "$f")"
#   done | sudo tee /srv/data/pragma >/dev/null
#   sudo chmod 600 /srv/data/pragma
#
# ── Stubs: --init-pragma, or answering yes at the prompt ─────
#
# For each secret with no entry, APPENDS a line holding the
# template's own placeholder — so API_JWT_SECRET_RMS arrives as
# "replace-me-with-a-32-byte-minimum-secret", carrying the shape of
# the wanted value into the file you are about to edit.
#
# It never touches a key that is already present, whatever it holds:
# filled, empty, or still a placeholder. The one thing this must
# never do is destroy a live secret.
#
# A stub is a to-do item, not a value. The build still refuses to run
# until you replace it, which is what makes scaffolding safe to
# offer at all.
#
# It does NOT invent real secrets. Generating 32 random bytes would
# work for a JWT key and is meaningless for an SMTP password, so you
# would end up with a file where some values are decisions and some
# are guesses, and nothing recording which.
#
# ── What it will not do ──────────────────────────────────────
#
# It refuses to write a .env that still contains a placeholder.
# A half-built .env and a good one look identical until postgres
# rejects the login, so the failure belongs here, where it can name
# the key that is missing.
# ============================================================
set -euo pipefail

# FIXED PATH. It deliberately does NOT follow HOST_DATA_ROOT.
#
# HOST_DATA_ROOT exists so that bulk data — a postgres cluster, a time-series
# store — can be moved onto an external drive and off the system disk. Secrets
# are a few kilobytes and never grow, so they have no reason to move with it.
#
# Letting them move was actively harmful: compose reads HOST_DATA_ROOT from
# .env, this script read it from the shell environment, and the two silently
# disagreed on any host with a data drive. Worst case it built a .env from a
# stale /srv/data/pragma while compose wrote data to /mnt/bigdisk, with no
# error anywhere. One fixed path removes that whole class of failure.
#
# PRAGMA_FILE is a TEST SEAM, not a supported production setting. Nothing on a
# real server should set it.
PRAGMA_FILE="${PRAGMA_FILE:-/srv/data/pragma}"
TEMPLATE="${TEMPLATE:-.env.example}"
OUTPUT="${OUTPUT:-.env}"
CHECK_ONLY=false
INIT_PRAGMA=false
NONINTERACTIVE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log()  { printf '[svc-build-env] %s\n' "$*"; }
warn() { printf '[svc-build-env] WARN: %s\n' "$*" >&2; }
die()  { printf '[svc-build-env] FATAL: %s\n' "$*" >&2; exit 1; }
# Bad usage exits 2, a runtime failure exits 1 — the agollum convention, and
# the same split svc-image-purge.sh uses.
usage() { printf '[svc-build-env] FATAL: %s\n' "$*" >&2; exit 2; }

while (( $# )); do
  case "$1" in
    --check)       CHECK_ONLY=true ;;
    # --init-creds is the pre-0.1.0 spelling, kept so existing runbooks and
    # scripts do not break on the rename. Same behaviour.
    --init-pragma|--init-creds) INIT_PRAGMA=true ;;
    # The house flag for "do not prompt". Here the prompt only ever offers to
    # create stubs, and the default answer is yes, so --defaults leaves a fresh
    # box one manual step from ready rather than making it guess a secret.
    --defaults)    NONINTERACTIVE=true ;;
    -h|--help) awk 'NR>4 && /^#/ { sub(/^# ?/,""); print; next } NR>4 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) usage "unknown argument: $1 (expected --check, --init-pragma or --defaults)" ;;
  esac
  shift
done

# Both read the template and report on the pragma file; they differ only in
# whether they are allowed to write. Picking a winner would be a guess.
if $CHECK_ONLY && $INIT_PRAGMA; then
  usage "--check and --init-pragma are mutually exclusive (--check writes nothing)"
fi

[[ -f "$TEMPLATE" ]] || die "$TEMPLATE not found (run this from the infra repo root)"

if [[ ! -f "$PRAGMA_FILE" ]]; then
  # A box still on the pre-0.1.0 layout gets the migration command rather than
  # a bare "not found", because that is the only reason this is ever missing on
  # a machine that was previously working.
  legacy="$(dirname "$PRAGMA_FILE")/creds"
  if [[ -d "$legacy" ]]; then
    die "$PRAGMA_FILE does not exist, but $legacy does.

This host is still on the pre-0.1.0 one-file-per-secret layout. There is no
fallback. Migrate it once:

  for f in $legacy/*; do
    [ -f \"\$f\" ] || continue
    k=\$(basename \"\$f\"); k=\${k%.txt}
    printf '%s=%s\\n' \"\$(printf '%s' \"\$k\" | tr 'a-z' 'A-Z')\" \"\$(head -1 \"\$f\")\"
  done | sudo tee $PRAGMA_FILE >/dev/null
  sudo chmod 600 $PRAGMA_FILE

Check the result before deleting $legacy — a multi-line secret in there will
not have survived the conversion, and needs to stay a file."
  fi
  die "$PRAGMA_FILE does not exist.

It holds every secret on this box, one KEY=value per line. It is deliberately
outside this repo and must be created by hand, once per server:

  sudo install -m 600 -o \"$(id -un)\" -g \"$(id -gn)\" /dev/null $PRAGMA_FILE

Owned by you, not root: this script runs as you, and a root-owned .env would
then be unreadable by docker compose.

The path is fixed. It does not follow HOST_DATA_ROOT — that variable moves bulk
data onto a separate drive, and secrets are a few kilobytes that never grow."
fi

# Check readability explicitly. Without this the failure lands on the redirect
# that reads the file, as a bare "line 275: /srv/data/pragma: Permission
# denied" — which names a line number in a script the reader did not write and
# says nothing about the actual problem, which is ownership.
if [[ ! -r "$PRAGMA_FILE" ]]; then
  die "$PRAGMA_FILE exists but is not readable by $(id -un).

  $(ls -l "$PRAGMA_FILE" 2>/dev/null)

It must be owned by the user who runs deploys, mode 600:

  sudo chown $(id -un):$(id -gn) $PRAGMA_FILE

Do NOT work around this by running this script under sudo. That writes a
root-owned .env, which docker compose then cannot read as $(id -un) — the same
failure, one step later and harder to place."
fi

pragma_mode="$(stat -c '%a' "$PRAGMA_FILE" 2>/dev/null || echo '?')"
if [[ "$pragma_mode" != "600" ]]; then
  warn "$PRAGMA_FILE is mode $pragma_mode, not 600."
  warn "Expected on /mnt/... under WSL (DrvFs has no permissions). On a server,"
  warn "this means every account on the box can read every secret."
fi

# ── parse the pragma file once ───────────────────────────────
# Keyed on the lowercased variable name, so POSTGRES_PASSWORD and
# postgres_password land on the same entry.
declare -A PRAGMA_VAL=()
declare -A PRAGMA_LINE=()
lineno=0
while IFS= read -r praw || [[ -n "$praw" ]]; do
  lineno=$((lineno+1))
  # Strip a UTF-8 BOM from the first line and a CR from any line: the file gets
  # edited from Windows, and a trailing CR would land inside the secret.
  (( lineno == 1 )) && praw="${praw#$'\xEF\xBB\xBF'}"
  praw="${praw%$'\r'}"

  # Blank, or a comment. '#' only counts at the start of the line — mid-value
  # it is an ordinary password character.
  [[ "$praw" =~ ^[[:space:]]*$ ]] && continue
  [[ "$praw" =~ ^[[:space:]]*# ]] && continue

  # Split on the FIRST '=' only. Base64 values end in '=' or '==', and a greedy
  # match would truncate every one of them.
  if [[ ! "$praw" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
    die "$PRAGMA_FILE line $lineno is not KEY=value, a comment, or blank:

  $praw

Silently skipping it would turn a typo into a missing secret, discovered later
as a login failure. Fix the line, or comment it out."
  fi

  pkey="${BASH_REMATCH[1],,}"
  pval="${BASH_REMATCH[2]}"

  if [[ -n "${PRAGMA_LINE[$pkey]:-}" ]]; then
    die "$PRAGMA_FILE defines '$pkey' twice, on lines ${PRAGMA_LINE[$pkey]} and $lineno.
Delete one. Guessing which is real is exactly the wrong thing to do here."
  fi

  # Trim surrounding whitespace, then strip ONE matching pair of quotes. The
  # quotes are how you express a value whose whitespace matters, so they have
  # to come off after the trim, not before.
  pval="${pval#"${pval%%[![:space:]]*}"}"
  pval="${pval%"${pval##*[![:space:]]}"}"
  if [[ ${#pval} -ge 2 ]]; then
    case "$pval" in
      \"*\") pval="${pval:1:${#pval}-2}" ;;
      \'*\') pval="${pval:1:${#pval}-2}" ;;
    esac
  fi

  PRAGMA_VAL["$pkey"]="$pval"
  PRAGMA_LINE["$pkey"]="$lineno"
done < "$PRAGMA_FILE"

filled=0
missing_names=()      # every secret that did not resolve, for the report
absent_names=()       # the subset with no entry at all — the stubbable ones
declare -A PLACEHOLDER=()
D='$'   # see the substitution below — must not be inlined
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Walk the template line by line rather than running sed over it.
# Secret values can contain /, & and \, all of which are special to
# sed's replacement — substituting them textually is how a password
# quietly becomes a different password.
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    printf '%s\n' "$line" >> "$tmp"
    continue
  fi

  var="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"

  # Not a placeholder: keep the template's own value, always.
  if [[ "${val,,}" != replace* ]]; then
    printf '%s\n' "$line" >> "$tmp"
    continue
  fi

  if [[ -z "${PRAGMA_LINE[${var,,}]:-}" ]]; then
    missing_names+=("$var")
    absent_names+=("$var")
    PLACEHOLDER["$var"]="$val"
    printf '%s\n' "$line" >> "$tmp"
    continue
  fi

  value="${PRAGMA_VAL[${var,,}]}"
  if [[ -z "$value" ]]; then
    warn "$PRAGMA_FILE line ${PRAGMA_LINE[${var,,}]}: $var is empty"
    missing_names+=("$var")
    printf '%s\n' "$line" >> "$tmp"
    continue
  fi

  # The key exists but holds the template text — someone pasted the placeholder
  # in rather than the secret, or it is a stub this script appended. Finding a
  # key is not the same as finding a value, and a .env full of "replace-me"
  # fails identically to a good one until postgres rejects the login. This
  # check is also what makes stubs safe to create at all.
  if [[ "${value,,}" == replace* ]]; then
    warn "$PRAGMA_FILE line ${PRAGMA_LINE[${var,,}]}: $var still holds a placeholder"
    missing_names+=("$var")
    printf '%s\n' "$line" >> "$tmp"
    continue
  fi

  # Double every literal $. Compose interpolates this file, so a lone
  # $ is read as a variable reference and silently eaten:
  #   pa$word  -> pa        (compose warns, never fails)
  #   pa$$word -> pa$word
  #
  # The replacement goes through a variable because bash expands the
  # replacement text: writing ${value//$/$$} literally substitutes the
  # shell's PID, turning pa$word into pa921word.
  escaped="${value//$D/$D$D}"

  # Re-quote on the way OUT if the value has leading or trailing whitespace.
  # Quotes in the pragma file are the only way to express such a value, and
  # they were stripped when it was read — writing it bare here would hand
  # compose "  spaced  " and let it trim, silently undoing the exact thing the
  # quotes were for. Compose understands a quoted value in .env.
  if [[ "$escaped" != "${escaped#[[:space:]]}" || "$escaped" != "${escaped%[[:space:]]}" ]]; then
    printf '%s="%s"\n' "$var" "$escaped" >> "$tmp"
  else
    printf '%s=%s\n' "$var" "$escaped" >> "$tmp"
  fi
  filled=$((filled+1))
done < "$TEMPLATE"

# ── report what is missing ───────────────────────────────────
report_missing() {
  printf '[svc-build-env] %d secret(s) unresolved in %s:\n' \
    "${#missing_names[@]}" "$PRAGMA_FILE" >&2
  local v where
  for v in "${missing_names[@]}"; do
    if [[ -n "${PRAGMA_LINE[${v,,}]:-}" ]]; then
      where="line ${PRAGMA_LINE[${v,,}]}"
    else
      where="not present"
    fi
    printf '  %-32s %s\n' "$v" "$where" >&2
  done
}

# ── append the stubs ─────────────────────────────────────────
# Only ever for names with no entry at all, so by construction there is nothing
# here to overwrite. The guard below is for the case where that is wrong.
# Reports through STUBS_CREATED rather than stdout. It logs as it goes, so
# returning the count on stdout too would mean $(write_stubs) captured the log
# lines as part of the number.
STUBS_CREATED=0
write_stubs() {
  local v block=""
  STUBS_CREATED=0
  (( ${#absent_names[@]} )) || return 0

  # Build the text FIRST, then append it in one write. Do not wrap the loop in
  # a `>> "$PRAGMA_FILE"` redirect: log() writes to stdout, so its output would
  # be captured by that redirect and land in the secrets file between the keys.
  # Ask how I know.
  for v in "${absent_names[@]}"; do
    if [[ -n "${PRAGMA_LINE[${v,,}]:-}" ]]; then
      warn "skipped $v — already in $PRAGMA_FILE"
      continue
    fi
    block+="$v=${PLACEHOLDER[$v]}"$'\n'
    STUBS_CREATED=$((STUBS_CREATED+1))
  done

  (( STUBS_CREATED )) || return 0

  # One append, not one per secret: a partial write from an interrupted loop is
  # harder to reason about than an all-or-nothing block.
  printf '\n# added by svc-build-env from %s/%s\n%s' \
    "$(basename "$PWD")" "$TEMPLATE" "$block" >> "$PRAGMA_FILE" \
    || { warn "could not append to $PRAGMA_FILE"; return 1; }

  for v in "${absent_names[@]}"; do
    [[ -n "${PRAGMA_LINE[${v,,}]:-}" ]] || log "appended  $v=${PLACEHOLDER[$v]}"
  done
}

# ── --check: report only, write nothing at all ───────────────
if $CHECK_ONLY; then
  if (( ${#missing_names[@]} )); then
    report_missing
    exit 1
  fi
  log "check passed — $filled secret(s) resolve, no placeholders left"
  exit 0
fi

# ── --init-pragma: append stubs, never build ─────────────────
if $INIT_PRAGMA; then
  if (( ${#absent_names[@]} == 0 )); then
    log "nothing to do — every secret in $TEMPLATE already has a key in $PRAGMA_FILE"
    exit 0
  fi
  write_stubs
  log "$STUBS_CREATED appended, $(( ${#missing_names[@]} - STUBS_CREATED )) already present but unresolved"
  log "edit $PRAGMA_FILE, then run ./svc-build-env.sh"
  exit 0
fi

# ── default: build, offering to stub what is absent ──────────
if (( ${#missing_names[@]} == 0 )); then
  # 0600 before any content lands, not after.
  install -m 600 /dev/null "$OUTPUT"
  cat "$tmp" > "$OUTPUT"

  # Verify rather than assume. On a Windows-mounted path (/mnt/c under WSL) the
  # filesystem is DrvFs, which has no real chmod, so the install above silently
  # does nothing and the file lands world-readable. That is tolerable on a dev box
  # and not on a server, but either way the script must not claim a mode it did
  # not get.
  mode="$(stat -c '%a' "$OUTPUT" 2>/dev/null || echo '?')"
  log "$OUTPUT written — $filled secret(s) filled from $PRAGMA_FILE"
  if [[ "$mode" != "600" ]]; then
    warn "$OUTPUT is mode $mode, not 600 — chmod did not take."
    warn "Expected on /mnt/... under WSL (DrvFs has no permissions). On a server,"
    warn "this means the secrets are readable by every account on the box."
  fi
  exit 0
fi

report_missing

if (( ${#absent_names[@]} )); then
  reply="y"
  if $NONINTERACTIVE; then
    log "--defaults: appending stubs without asking"
  elif [[ ! -t 0 ]]; then
    log "no terminal on stdin: appending stubs without asking"
  else
    printf '\nAppend %d stub(s) to %s, pre-filled with the placeholder from %s? [Y/n]: ' \
      "${#absent_names[@]}" "$PRAGMA_FILE" "$TEMPLATE"
    read -r reply || reply=""
    [[ -z "$reply" ]] && reply="y"
  fi
  if [[ "${reply,,}" == y* ]]; then
    printf '\n'
    write_stubs
  fi
fi

# Deliberately not retried after stubbing: a stub holds a placeholder, and the
# check above rejects those, so a build could not succeed anyway. .env is the
# deliverable, so no .env means a non-zero exit — otherwise
# `./svc-build-env.sh && ./svc-start.sh` would march on without one.
printf '\n' >&2
die "$OUTPUT NOT written — the values above are still placeholders.
Fill them in, then run ./svc-build-env.sh again."
