#!/usr/bin/env bash
# svc-scripts 0.0.0 — canonical copy: agollum/docker/services/
# Edit there and copy the whole set across; svc-compose.sh is sourced by
# the others, so a half-updated set breaks in ways that look like a bug.
# ============================================================
# Build .env from .env.example, filling secrets from a creds dir.
#
#   ./svc-build-env.sh                # build; offer to stub whatever is missing
#   ./svc-build-env.sh --defaults     # same, but never prompt (takes the yes)
#   ./svc-build-env.sh --init-creds   # only write the stubs, never build .env
#   ./svc-build-env.sh --check        # report only, write nothing at all
#   CREDS_DIR=/some/where ./svc-build-env.sh
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
#   SMTP_USER=replace@me.com        -> needs a cred
#   LOG_LEVEL=info                  -> passed through untouched
#
# It used to look for a cred file for EVERY variable and use one if
# it happened to exist, so a stray log_level.txt would silently
# override a setting that is not a secret.
#
# ── The creds directory ──────────────────────────────────────
#
# One file per secret, named after the variable. Case does not
# matter and .txt is optional, so all of these work for SMTP_USER:
#
#   smtp_user.txt   SMTP_USER.txt   smtp_user   SMTP_USER
#
# Two files claiming the same secret is an error, not a coin toss.
#
# The directory is not in this repo and cannot be — it must be placed
# by hand once per server, root-owned and chmod 700. This script
# writes files inside it, but will not create it.
#
# It is FLAT and shared by every project on the box, keyed on the
# variable name alone. So a variable's name must be unique exactly
# when its value must be unique: POSTGRES_USER is one database role
# and therefore one file, while API_JWT_SECRET_RMS and
# API_JWT_SECRET_TALOSOT are two signing keys and therefore two.
# Giving two different secrets one name is how two services end up
# able to forge each other's tokens.
#
# ── Stubs: --init-creds, or answering yes at the prompt ──────
#
# For each secret with NO cred file, writes one holding the
# template's own placeholder — so api_jwt_secret_rms starts life
# containing "replace-me-with-a-32-byte-minimum-secret", which
# carries the shape of the wanted value to the file you edit.
#
# It never overwrites. A file that already exists is left exactly as
# it is, whether it is filled, empty, or still a placeholder — the
# one thing this must never do is destroy a live secret.
#
# A stub is a to-do item, not a value. The build still refuses to run
# until you replace it, which is what makes scaffolding safe to
# offer at all.
#
# It does NOT invent real secrets. Generating 32 random bytes would
# work for a JWT key and is meaningless for an SMTP password, so you
# would end up with a directory where some files are decisions and
# some are guesses, and nothing recording which.
#
# ── What it will not do ──────────────────────────────────────
#
# It refuses to write a .env that still contains a placeholder.
# A half-built .env and a good one look identical until postgres
# rejects the login, so the failure belongs here, where it can name
# the file that is missing.
# ============================================================
set -euo pipefail

# Host-level, alongside certs — not under PROJECT_DATA_ROOT. One
# creds directory serves every project on the box.
CREDS_DIR="${CREDS_DIR:-${HOST_DATA_ROOT:-/srv/data}/creds}"
TEMPLATE="${TEMPLATE:-.env.example}"
OUTPUT="${OUTPUT:-.env}"
CHECK_ONLY=false
INIT_CREDS=false
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
    --check)      CHECK_ONLY=true ;;
    --init-creds) INIT_CREDS=true ;;
    # The house flag for "do not prompt". Here the prompt only ever offers to
    # create stubs, and the default answer is yes, so --defaults leaves a fresh
    # box one manual step from ready rather than making it guess a secret.
    --defaults)   NONINTERACTIVE=true ;;
    -h|--help) awk 'NR>4 && /^#/ { sub(/^# ?/,""); print; next } NR>4 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) usage "unknown argument: $1 (expected --check, --init-creds or --defaults)" ;;
  esac
  shift
done

# Both read the template and report on the creds directory; they differ only in
# whether they are allowed to write. Picking a winner would be a guess.
if $CHECK_ONLY && $INIT_CREDS; then
  usage "--check and --init-creds are mutually exclusive (--check writes nothing)"
fi

[[ -f "$TEMPLATE" ]] || die "$TEMPLATE not found (run this from the infra repo root)"
[[ -d "$CREDS_DIR" ]] || die "creds directory $CREDS_DIR does not exist.
It holds one file per secret, named after the variable — e.g.
  $CREDS_DIR/postgres_password
It is deliberately outside this repo and must be created by hand:
  sudo mkdir -p $CREDS_DIR && sudo chmod 700 $CREDS_DIR
Point somewhere else with CREDS_DIR=/path ./svc-build-env.sh"

# ── index the creds directory once ───────────────────────────
# Key is the filename lowercased with a trailing .txt removed, so
# SMTP_USER.txt, smtp_user.txt and smtp_user all land on smtp_user.
declare -A CRED_PATH=()
for f in "$CREDS_DIR"/*; do
  [[ -f "$f" ]] || continue
  key="$(basename "$f")"
  key="${key%.txt}"
  key="${key,,}"
  if [[ -n "${CRED_PATH[$key]:-}" ]]; then
    die "two files in $CREDS_DIR both claim the secret '$key':
  ${CRED_PATH[$key]}
  $f
Delete one. Guessing which is real is exactly the wrong thing to do here."
  fi
  CRED_PATH["$key"]="$f"
done

# Read a cred file: strip a UTF-8 BOM, strip CR (files authored on
# Windows carry one, and it would land inside the secret), then take
# the first non-empty line and trim surrounding whitespace.
read_cred() {
  local path="$1" value
  value="$(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$path" | grep -m1 -v '^[[:space:]]*$' || true)"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

filled=0
missing_names=()      # every secret that did not resolve, for the report
absent_names=()       # the subset with no cred file at all — the stubbable ones
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

  cred_file="${CRED_PATH[${var,,}]:-}"
  if [[ -z "$cred_file" ]]; then
    missing_names+=("$var")
    absent_names+=("$var")
    PLACEHOLDER["$var"]="$val"
    printf '%s\n' "$line" >> "$tmp"
    continue
  fi

  value="$(read_cred "$cred_file")"
  if [[ -z "$value" ]]; then
    warn "$cred_file is empty"
    missing_names+=("$var")
    printf '%s\n' "$line" >> "$tmp"
    continue
  fi

  # The cred file exists but holds the template text — someone copied the
  # placeholder in rather than the secret, or it is a stub this script wrote.
  # Finding a file is not the same as finding a value, and a .env full of
  # "replace-me" fails identically to a good one until postgres rejects the
  # login. This check is also what makes stubs safe to create at all.
  if [[ "${value,,}" == replace* ]]; then
    warn "$cred_file still contains a placeholder"
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
  printf '%s=%s\n' "$var" "${value//$D/$D$D}" >> "$tmp"
  filled=$((filled+1))
done < "$TEMPLATE"

# ── report what is missing ───────────────────────────────────
report_missing() {
  printf '[svc-build-env] %d secret(s) unresolved:\n' "${#missing_names[@]}" >&2
  local v
  for v in "${missing_names[@]}"; do
    printf '  %-28s %s/%s\n' "$v" "$CREDS_DIR" "${v,,}" >&2
  done
}

# ── write the stubs ──────────────────────────────────────────
# Only ever for names with no cred file under ANY accepted spelling, so by
# construction there is nothing here to overwrite. The -e guard below is for
# the case where that construction is wrong.
# Reports through STUBS_CREATED rather than stdout. It logs as it goes, so
# returning the count on stdout too would mean $(write_stubs) captured the log
# lines as part of the number.
STUBS_CREATED=0
write_stubs() {
  local v path mode
  STUBS_CREATED=0
  for v in "${absent_names[@]}"; do
    path="$CREDS_DIR/${v,,}"
    if [[ -e "$path" ]]; then
      warn "skipped $path — it already exists"
      continue
    fi
    # 0600 before any content lands, not after.
    install -m 600 /dev/null "$path" 2>/dev/null || { warn "could not create $path"; continue; }
    printf '%s\n' "${PLACEHOLDER[$v]}" > "$path"
    mode="$(stat -c '%a' "$path" 2>/dev/null || echo '?')"
    [[ "$mode" == "600" ]] || warn "$path is mode $mode, not 600 — chmod did not take"
    log "created  $path  (${PLACEHOLDER[$v]})"
    STUBS_CREATED=$((STUBS_CREATED+1))
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

# ── --init-creds: write stubs, never build ───────────────────
if $INIT_CREDS; then
  if (( ${#absent_names[@]} == 0 )); then
    log "nothing to do — every secret in $TEMPLATE already has a file in $CREDS_DIR"
    exit 0
  fi
  write_stubs
  log "$STUBS_CREATED created, $(( ${#missing_names[@]} - STUBS_CREATED )) already present but unresolved"
  log "fill them in, then run ./svc-build-env.sh"
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
  log "$OUTPUT written — $filled secret(s) filled from $CREDS_DIR"
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
    log "--defaults: creating stubs without asking"
  elif [[ ! -t 0 ]]; then
    log "no terminal on stdin: creating stubs without asking"
  else
    printf '\nCreate %d stub(s) in %s, pre-filled with the placeholder from %s? [Y/n]: ' \
      "${#absent_names[@]}" "$CREDS_DIR" "$TEMPLATE"
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
