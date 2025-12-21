#!/usr/bin/env bash
# mailx-wrapper (GNU Mailutils mailx)
#
# Behavior:
# - Passes through all args to mailx unchanged
# - If invoked with -V anywhere: prints a custom string and exits
# - If invoked with --smtp <FILE>:
#     * Reads ALL SMTP-related settings from FILE (a simple key=value format)
#     * Forces SMTP transport via --exec 'set sendmail="smtp://...";'
#
# SMTP config file format (key=value, # comments allowed):
#   host=smtp.example.com
#   port=587                 # optional (defaults: 587 for smtp, 465 for smtps)
#   proto=smtp               # smtp or smtps (optional; default smtp)
#   tls_required=yes         # yes/no (optional; default yes)
#   user=user%40example.com
#   password=secret          # or: password_file=/path/to/file
#   # optional extras:
#   auth=yes                 # yes/no (optional; default yes)
#
# Examples:
#   mailx-wrapper --smtp ~/.config/mailx-smtp.conf -s "hi" you@example.com < body.txt
#
# Security:
#   chmod 600 your smtp config file and any password_file

set -euo pipefail

MAILX_BIN="${MAILX_BIN:-mailx}"
WRAPPER_V_STRING="${WRAPPER_V_STRING:-mailx-wrapper 1.0 (GNU Mailutils mailx wrapper)}"

die() { printf 'mailx-wrapper: %s\n' "$*" >&2; exit 2; }

strip_trailing_newlines() {
  local s="${1-}"
  s="${s%$'\n'}"; s="${s%$'\r'}"
  printf '%s' "$s"
}

trim() {
  local s="${1-}"
  # trim leading
  s="${s#"${s%%[![:space:]]*}"}"
  # trim trailing
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() {
  local s="${1-}"
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]'
}

bool_norm() {
  # Accept yes/no, on/off, true/false, 1/0
  local v
  v="$(lower "$(trim "${1-}")")"
  case "$v" in
    yes|on|true|1) printf 'yes' ;;
    no|off|false|0) printf 'no' ;;
    *) die "invalid boolean value: '$1' (expected yes/no, on/off, true/false, 1/0)" ;;
  esac
}

# -----------------------------------------------------------------------------
# -V interception (anywhere)
for a in "$@"; do
  if [[ "$a" == "-V" ]]; then
    printf '%s\n' "$WRAPPER_V_STRING"
    exit 0
  fi
done

# -----------------------------------------------------------------------------
# Parse wrapper option: --smtp <FILE> (everything else passthru)
smtp_cfg_file=""
passthru=()

while (($#)); do
  case "$1" in
    --smtp)
      smtp_cfg_file="${2-}"
      [[ -n "$smtp_cfg_file" ]] || die "--smtp requires a file path argument"
      shift 2
      ;;
    --)
      shift
      while (($#)); do passthru+=("$1"); shift; done
      ;;
    *)
      passthru+=("$1")
      shift
      ;;
  esac
done

# -----------------------------------------------------------------------------
# If no SMTP config requested, just exec mailx
if [[ -z "$smtp_cfg_file" ]]; then
  exec "$MAILX_BIN" "${passthru[@]}"
fi

# -----------------------------------------------------------------------------
# Read SMTP config file (simple key=value)
[[ -r "$smtp_cfg_file" ]] || die "cannot read SMTP config file: $smtp_cfg_file"

host=""
port=""
proto="smtp"
tls_required="yes"
auth="yes"
user=""
password=""
password_file=""

while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip comments (very simple: # starts comment)
  line="${line%%#*}"
  line="$(trim "$line")"
  [[ -z "$line" ]] && continue

  if [[ "$line" != *"="* ]]; then
    die "bad line (expected key=value) in $smtp_cfg_file: $line"
  fi

  key="$(trim "${line%%=*}")"
  val="$(trim "${line#*=}")"

  key="$(lower "$key")"

  case "$key" in
    host) host="$val" ;;
    port) port="$val" ;;
    proto|protocol) proto="$(lower "$val")" ;;
    tls_required|tls-required) tls_required="$(bool_norm "$val")" ;;
    auth) auth="$(bool_norm "$val")" ;;
    user|username) user="$val" ;;
    password) password="$val" ;;
    password_file|password-file) password_file="$val" ;;
    *)
      die "unknown key '$key' in $smtp_cfg_file"
      ;;
  esac
done < "$smtp_cfg_file"

[[ -n "$host" ]] || die "missing required key: host"
[[ -n "$user" ]] || die "missing required key: user (or username)"
case "$proto" in
  smtp|smtps) ;;
  *) die "proto must be smtp or smtps (got '$proto')" ;;
esac

if [[ -z "$port" ]]; then
  if [[ "$proto" == "smtps" ]]; then port="465"; else port="587"; fi
fi

if [[ -n "$password_file" && -z "$password" ]]; then
  [[ -r "$password_file" ]] || die "cannot read password_file: $password_file"
  password="$(strip_trailing_newlines "$(<"$password_file")")"
fi
[[ -n "$password" ]] || die "missing credentials: provide password=... or password_file=..."

# -----------------------------------------------------------------------------
# Build temporary Mailutils config for credentials/TLS

# Escape only double-quotes for the Mailutils string literals
esc_user="${user//\"/\\\"}"
esc_pass="${password//\"/\\\"}"

# Force transport selection in mailx (mailrc-style command).
# Credentials stay in the mailutils config above; URL is just transport + host/port + flags.
sendmail_url="${proto}://${esc_user}:${esc_pass}@${host}:${port}"
if [[ "$tls_required" == "yes" ]]; then
  sendmail_url="${sendmail_url};tls-required"
fi

#echo "$MAILX_BIN" \
#  --exec "set sendmail=\"${sendmail_url}\"" \
#  "${passthru[@]}"
exec "$MAILX_BIN" \
  --exec "set sendmail=\"${sendmail_url}\"" \
  "${passthru[@]}"
