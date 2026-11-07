#!/bin/sh
# tv-verify — `tweak.sh verify` against each TV named on the command line, for a timer: one line per
# TV, its FAIL and WARN lines under it, and the same report to a webhook when any TV failed. A TV
# that does not answer counts as failed: a stick whose ADB went away has drifted too. Nothing on a
# TV changes, verify only reads. Exit 0 when every TV passed, 1 otherwise, 2 on a usage error.
#   tv-verify.sh [--webhook <url>] <profile>=<ip:port> [<profile>=<ip:port> ...]
# WEBHOOK_URL is the same as --webhook; the body is {"content": "..."}, which Discord-style webhooks
# take, and nothing is posted while every TV passes. TWEAK_SH names another tweak.sh (the one beside
# this directory by default); DEVICE is set per TV from the argument, and the rest of tweak.sh's
# environment (ADB, TWEAK_STATE) passes through. docs/homelab.md says where to run it from.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TWEAK=${TWEAK_SH:-$HERE/../tweak.sh}
WEBHOOK=${WEBHOOK_URL:-}
NL='
'

usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
usage_error() { echo "error: $*" >&2; echo "see: $0 --help" >&2; exit 2; }

targets=
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --webhook) [ $# -ge 2 ] || usage_error "--webhook takes a URL"; WEBHOOK=$2; shift ;;
        --webhook=*) WEBHOOK=${1#--webhook=} ;;
        -*) usage_error "unknown option '$1'" ;;
        *=*)
            # The profile name reaches tweak.sh --device and the target its DEVICE; both are checked
            # here, so a typo is a usage error before anything connects.
            case ${1%%=*} in ''|*[!a-z0-9-]*) usage_error "'$1' is not <profile>=<ip:port>" ;; esac
            case ${1#*=} in ''|*[!A-Za-z0-9_.:-]*) usage_error "'$1' is not <profile>=<ip:port>" ;; esac
            targets="$targets $1" ;;
        *) usage_error "'$1' is not <profile>=<ip:port>" ;;
    esac
    shift
done
[ -n "$targets" ] || usage_error "name at least one TV as <profile>=<ip:port>"
# The report names packages and settings; it goes nowhere in the clear.
case $WEBHOOK in ''|https://*) ;; *) usage_error "the webhook must be an https:// URL" ;; esac
[ -f "$TWEAK" ] || { echo "error: $TWEAK is not there; set TWEAK_SH" >&2; exit 1; }

n=0; bad=0; report=
for t in $targets; do
    n=$((n + 1))
    # verify's exit status is the verdict; its FAIL and WARN lines, and tweak.sh's own error when
    # the TV does not answer, are the detail worth carrying.
    if out=$(DEVICE=${t#*=} sh "$TWEAK" --device "${t%%=*}" verify 2>&1); then
        line="ok    ${t%%=*} ${t#*=}"
    else
        bad=$((bad + 1)); line="FAIL  ${t%%=*} ${t#*=}"
    fi
    detail=$(printf '%s\n' "$out" | grep -E '^(  (FAIL|WARN) |error: )' || true)
    echo "$line"
    [ -z "$detail" ] || printf '%s\n' "$detail"
    report="$report$line$NL${detail:+$detail$NL}"
done

if [ "$bad" -gt 0 ] && [ -n "$WEBHOOK" ]; then
    # JSON by hand: tabs to spaces, backslashes and quotes escaped, newlines as \n; a Discord message
    # takes 2000 characters, so the report is cut well under that.
    body=$(printf '%s' "$report" | head -c 1800 | tr '\t' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g' \
        | awk 'NR > 1 {printf "\\n"} {printf "%s", $0}')
    printf '{"content": "tv-verify: %s of %s TVs failed\\n%s"}' "$bad" "$n" "$body" \
        | curl -fsS -m 20 -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK" >/dev/null \
        || echo "error: the webhook did not take the report" >&2
fi
[ "$bad" -eq 0 ] || exit 1
