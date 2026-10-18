#!/bin/sh
# tweak — debloat and tune an Android TV device over ADB. No root required.
# Everything device-specific lives in devices/<profile>/; the README lists the verified devices.
set -eu

VERSION=0.1.0
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEVICE=${DEVICE:-}
ADB=${ADB:-adb}
# Android Studio installs platform-tools but does not put it on PATH. Only guess when the caller
# did not name one, so an explicit ADB= still fails loudly instead of being silently replaced.
if [ "$ADB" = adb ] && ! command -v adb >/dev/null 2>&1; then
    for c in "$HOME/Library/Android/sdk/platform-tools/adb" \
             "$HOME/Android/Sdk/platform-tools/adb" \
             /usr/local/bin/adb /opt/homebrew/bin/adb; do
        if [ -x "$c" ]; then ADB=$c; break; fi
    done
fi
PROFILE=${TWEAK_PROFILE:-}
CONF=${TWEAK_CONF:-}
MEDIA_APPS=${TWEAK_MEDIA_APPS:-}
# The undo record lives outside the clone, one directory per TV: in backups/ inside the clone a
# re-clone or `git clean -fdx` took it away, and two TVs of one model shared and overwrote it.
if [ -n "${TWEAK_STATE:-}" ]; then STATE_ROOT=$TWEAK_STATE
elif [ "$(uname -s)" = Darwin ]; then STATE_ROOT="$HOME/Library/Application Support/tv-tweak"
else STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/tv-tweak"
fi
STATE=; LOGGING=; NEW_DEVICE=; FORCE=; DRY_RUN=

die() { echo "error: $*" >&2; if [ -n "$LOGGING" ]; then log "error: $*"; fi; exit 1; }
usage_error() { echo "error: $*" >&2; echo "see: $0 --help" >&2; exit 2; }
profiles() { for d in "$HERE"/devices/*/; do basename "$d"; done | tr '\n' ' '; }

# Everything that ends up on the TV's command line goes through one of these first: `adb shell`
# joins its arguments with spaces and the TV's shell parses the result, so an unchecked value is
# a command.
is_tok() { case $1 in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac; }
is_pkg() { case $1 in ''|*[!A-Za-z0-9_.]*|[!A-Za-z]*|*.|*..*|*.[!A-Za-z]*) return 1 ;; esac; }
is_profile() { case $1 in ''|-*|*[!a-z0-9-]*) return 1 ;; esac; }
# Private DNS takes a hostname only: an IP address, like any name that does not resolve, leaves the
# TV with no DNS at all.
is_host() {
    case $1 in ''|-*|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;; *[!0-9.]*) ;; *) return 1 ;; esac
    case $1 in *.*) return 0 ;; esac
    return 1
}
valid_minutes() { case $1 in ''|0*|*[!0-9]*|??????*) return 1 ;; esac; [ "$1" -le 35791 ]; }
NL='
'

# Every adb call has a time limit: a TV that stops answering would otherwise hang the run. GNU
# timeout on Linux, gtimeout from Homebrew, otherwise perl's alarm, which macOS ships. --foreground
# keeps Ctrl+C reaching adb.
ADB_TIMEOUT=${TWEAK_TIMEOUT:-60}
case $ADB_TIMEOUT in ''|0*|*[!0-9]*) die "TWEAK_TIMEOUT must be a number of seconds" ;; esac
if timeout --foreground 1 true 2>/dev/null; then TIMER='timeout --foreground'
elif command -v timeout >/dev/null 2>&1; then TIMER=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMER='gtimeout --foreground'
elif command -v perl >/dev/null 2>&1; then TIMER=perl
else TIMER=
fi
# shellcheck disable=SC2016,SC2086  # perl code in single quotes; TIMER may carry --foreground
timed() {
    secs=$1; shift
    case $TIMER in
        '') "$@" ;;
        perl) perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!\n"' "$secs" "$@" ;;
        *) $TIMER "$secs" "$@" ;;
    esac
}

# stdin is closed: `adb shell` otherwise consumes the caller's stdin, which silently
# swallows the rest of the input in `while read ... done < file` loops.
sh_() { timed "$ADB_TIMEOUT" "$ADB" -s "$DEVICE" shell "$@" </dev/null; }
kept() { printf '%s\n' "$PROTECTED" | grep -qxF -- "$1"; }

# Reads from the TV. A failed read is an error, never an empty answer: an unreadable list of disabled
# packages, as right after a reboot, once made verify print "ok" and backup record nothing.
dev() { _out=$(sh_ "$@") || return 1; printf '%s\n' "$_out" | tr -d '\r'; }
pkg_list() {
    _out=$(dev "pm list packages $1") || die "could not read the package list from $DEVICE (pm list packages $1)"
    printf '%s\n' "$_out" | sed -n 's/^package://p'
}
# After a failure: is the TV still answering? A lost connection stops the run instead of turning
# every remaining step into a FAILED line.
alive() { sh_ true >/dev/null 2>&1; }
# The TV's own reason for a failure, short: $1 is what it printed, $2 the exit status, $3 the time
# limit it ran under. A timed-out call ends in 124 (timeout), 142 (perl's alarm) or, when timeout's
# own signal reaches it first, 143.
reason() {
    case $2 in 124|137|142|143) echo "no answer within ${3:-$ADB_TIMEOUT}s"; return ;; esac
    case $1 in
        *'error: device'*|*'error: closed'*|*'no devices'*|*offline*) echo "lost the connection" ;;
        *SecurityException*|*'protected package'*) echo "protected by the system" ;;
        *'Unknown package'*|*'Unknown component'*|*'not installed'*) echo "not installed" ;;
        '') echo "exit status $2" ;;
        *) printf '%s\n' "$1" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -1 ;;
    esac
}
# Quotes a value for the TV's shell, which re-parses everything `adb shell` sends.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Every profile file goes through this one filter, so CRLF endings, stray spaces and a comment after
# an entry mean the same everywhere; keep.conf used to read "pkg # note" as a different package and
# leave pkg unprotected. A comment is a # at the start of a line or after whitespace, so a URL
# fragment survives.
conf_lines() {
    tr -d '\r' < "$1" | sed 's/^#.*//; s/[[:space:]]#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -v '^$' || true
}

# device.conf is data, not code: only key="value" lines with known keys and plain characters.
read_device_conf() {
    model=; device=; tiers=; launcher=; media_apps=; props=; android=
    while IFS= read -r line; do
        case $line in
            '') continue ;;
            [a-z]*=\"*\") key=${line%%=*}; val=${line#*=\"}; val=${val%\"} ;;
            *) die "$1: expected key=\"value\", got: $line" ;;
        esac
        case $val in *[!A-Za-z0-9_.=:/,+' '-]*) die "$1: unexpected character in $key" ;; esac
        case $key in
            model) model=$val ;;
            device) device=$val ;;
            tiers) tiers=$val ;;
            launcher) launcher=$val ;;
            media_apps) media_apps=$val ;;
            props) props=$val ;;
            android) android=$val ;;
            *) die "$1: unknown key '$key'" ;;
        esac
    done <<EOF
$(conf_lines "$1")
EOF
    if [ -z "$model" ] || [ -z "$device" ] || [ -z "$tiers" ] || [ -z "$launcher" ]; then
        die "$1 must set model, device, tiers and launcher"
    fi
    for x in $tiers $android; do is_tok "$x" || die "$1: bad value '$x'"; done
    for x in $launcher $media_apps; do is_pkg "$x" || die "$1: '$x' is not a package name"; done
    for x in $props; do
        if ! is_tok "${x%%=*}" || ! is_tok "${x#*=}"; then die "$1: props wants key=value pairs, got '$x'"; fi
    done
}

# Prints each malformed line of a profile file; a profile with one stops the run.
bad_lines() {
    case $2 in
        packages) conf_lines "$1" | while read -r tier pkg rest; do
                      { is_tok "$tier" && is_pkg "${pkg:-}" && [ -z "${rest:-}" ]; } || echo "  $tier ${pkg:-} ${rest:-}"
                  done ;;
        keep)     conf_lines "$1" | while read -r pkg rest; do
                      { is_pkg "$pkg" && [ -z "${rest:-}" ]; } || echo "  $pkg ${rest:-}"
                  done ;;
        settings) conf_lines "$1" | while read -r ns key value rest; do
                      case $ns in global|secure|system) ;; *) echo "  $ns $key"; continue ;; esac
                      { is_tok "${key:-}" && is_tok "${value:-}" && [ -z "${rest:-}" ]; } || echo "  $ns ${key:-} ${value:-} ${rest:-}"
                  done ;;
        apps)     conf_lines "$1" | while IFS='|' read -r pkg url sum rest; do
                      if ! is_pkg "$pkg" || [ -n "${rest:-}" ]; then echo "  $pkg"; continue; fi
                      case $url in
                          play) [ -z "$sum" ] || echo "  $pkg: a play entry takes no checksum" ;;
                          https://*) case $sum in *[!0-9a-f]*|'') echo "  $pkg: checksum is not hex" ;; esac
                                     [ ${#sum} -eq 64 ] || echo "  $pkg: checksum is not a sha256" ;;
                          *) echo "  $pkg: url must be https:// or play" ;;
                      esac
                  done ;;
    esac
}
check_file() {
    bad=$(bad_lines "$1" "$2")
    [ -z "$bad" ] || die "$1 has malformed lines:
$bad"
}

# `--device <name>` or PROFILE= picks devices/<name>. Otherwise ro.product.model is matched
# against every device.conf, which needs a connected device first.
load_profile() {
    if [ -z "$PROFILE" ]; then
        m=$(dev getprop ro.product.model) || die "could not read the model from $DEVICE"
        for d in "$HERE"/devices/*/; do
            if [ -f "$d/device.conf" ] && conf_lines "$d/device.conf" | grep -qxF "model=\"$m\""; then
                PROFILE=$(basename "$d"); break
            fi
        done
        [ -n "$PROFILE" ] || die "no profile in devices/ matches model '$m'. Profiles are made per device, and another device's package list can break playback: see 'Adding a device' in the README, or compare one with '$0 --device <profile> verify'"
    fi
    # This profile's first name was that of a different device: Amazon also sells a Fire TV Stick HD.
    if [ "$PROFILE" = firetv-stick-hd ]; then
        echo "note: profile firetv-stick-hd is now firetv-stick-4k-max-2023 (Fire TV Stick 4K Max, 2nd gen)" >&2
        PROFILE=firetv-stick-4k-max-2023
    fi
    is_profile "$PROFILE" || die "invalid profile name '$PROFILE'"
    PROFILE_DIR="$HERE/devices/$PROFILE"
    [ -f "$PROFILE_DIR/device.conf" ] \
        || die "unknown profile '$PROFILE'; available: $(profiles)"
    read_device_conf "$PROFILE_DIR/device.conf"
    CONF=${CONF:-$PROFILE_DIR/packages.conf}
    [ -f "$CONF" ] || die "$CONF is missing"
    check_file "$CONF" packages
    # Protected packages are enforced independently of packages.conf so a bad edit cannot brick
    # playback — which only holds if keep.conf fails closed.
    [ -s "$PROFILE_DIR/keep.conf" ] \
        || die "$PROFILE_DIR/keep.conf is missing or empty; it keeps playback working, so nothing runs without it"
    check_file "$PROFILE_DIR/keep.conf" keep
    KEEP=$(conf_lines "$PROFILE_DIR/keep.conf")
    [ -n "$KEEP" ] || die "$PROFILE_DIR/keep.conf lists no packages"
    APPS=; SETTINGS=
    if [ -f "$PROFILE_DIR/apps.conf" ]; then
        check_file "$PROFILE_DIR/apps.conf" apps; APPS=$(conf_lines "$PROFILE_DIR/apps.conf")
    fi
    if [ -f "$PROFILE_DIR/settings.conf" ]; then
        check_file "$PROFILE_DIR/settings.conf" settings; SETTINGS=$(conf_lines "$PROFILE_DIR/settings.conf")
    fi
    MEDIA_APPS=${MEDIA_APPS:-$media_apps}
    for x in $MEDIA_APPS; do is_pkg "$x" || die "MEDIA_APPS: '$x' is not a package name"; done
    # Streaming apps are protected too, whether or not keep.conf repeats them.
    # shellcheck disable=SC2086  # media_apps is a space-separated list of package names
    PROTECTED=$({ printf '%s\n' "$KEEP"; printf '%s\n' $MEDIA_APPS; } | sort -u)
}

# Every setting this tool writes is recorded first, with the value it replaces, so `verify` can prove
# it survived a reboot and `restore` can put the original back. Recording before writing means a
# write that lands just as the connection drops cannot leave the tuned value to be taken for the
# original next time.
put_setting() {
    if ! old=$(dev settings get "$1" "$2"); then
        echo "  FAILED   $2: could not read its current value" >&2; return 1
    fi
    case $old in *"$NL"*) echo "  FAILED   $2: its current value spans lines; left alone" >&2; return 1 ;; esac
    if [ -n "$DRY_RUN" ]; then
        if [ "$old" = "$3" ]; then echo "  $2 is already $3"; else echo "  would set $2: $old -> $3"; fi
        return 0
    fi
    # "null" is how `settings get` says unset; any other value is kept shell-quoted, spaces and all.
    [ "$old" = null ] || old=$(q "$old")
    # Keep the first original ever seen: re-running tune must not record our own value as the
    # thing to roll back to.
    if prev=$(awk -v n="$1" -v k="$2" '$1 == n && $2 == k {sub(/^[^ ]+ [^ ]+ [^ ]+ ?/, ""); print; f = 1; exit}
                                      END {exit !f}' "$SETTINGS_FILE" 2>/dev/null); then
        old=$prev
    fi
    mkdir -p "$STATE"
    { awk -v n="$1" -v k="$2" '!($1 == n && $2 == k)' "$SETTINGS_FILE" 2>/dev/null || true
      echo "$1 $2 $3 $old"; } > "$SETTINGS_FILE.tmp"
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    if out=$(sh_ settings put "$1" "$2" "$3" 2>&1); then
        echo "  $2 = $3"
    else
        rc=$?; echo "  FAILED   $2: $(reason "$out" "$rc")" >&2; return 1
    fi
}

# macOS ships shasum but not sha256sum; most Linux distributions ship the reverse.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# TV-only apps declare LEANBACK_LAUNCHER only; sideloaded phone apps declare LAUNCHER only.
# Trying just one silently fails to start half of them.
start_pkg() {
    for cat in android.intent.category.LEANBACK_LAUNCHER android.intent.category.LAUNCHER; do
        if sh_ monkey -p "$1" -c "$cat" 1 2>/dev/null | grep -q 'Events injected'; then
            return 0
        fi
    done
    return 1
}

# Emits packages for the given tiers, minus anything on KEEP.
tier_pkgs() {
    for t in "$@"; do
        conf_lines "$CONF" | awk -v t="$t" '$1 == t {print $2}'
    done | sort -u | while read -r p; do
        if kept "$p"; then
            echo "skip (protected): $p" >&2
        else
            echo "$p"
        fi
    done
}

# A launcher set with `home` is a preferred activity, which `resolve-activity` ignores on Google
# TV in favour of the stock launcher's higher priority, so read the preference first.
home_activity() {
    xml=$(dev dumpsys package preferred-xml) || return 1
    pref=$(printf '%s\n' "$xml" | awk '
        /<item name="/ { sub(/.*<item name="/, ""); sub(/".*/, ""); item = $0 }
        /android\.intent\.category\.HOME/ && item != "" { print item; exit }')
    if [ -n "$pref" ]; then echo "$pref"; return 0; fi
    res=$(dev 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME --user 0') \
        || return 1
    printf '%s\n' "$res" | tail -1
}

connect() {
    command -v "$ADB" >/dev/null 2>&1 \
        || die "adb not found. Install Android platform-tools and put it on PATH, or set ADB=/path/to/adb"
    if [ -z "$DEVICE" ]; then
        DEVICE=$("$ADB" devices | awk '$2=="device" {print $1}' | head -2 | tr '\n' ' ')
        # Both classic TCP adb and Android 11+ wireless debugging (which moves to a new port on
        # every boot) advertise themselves over mDNS, so look there before giving up.
        if [ -z "$DEVICE" ]; then
            DEVICE=$("$ADB" mdns services 2>/dev/null | awk '$2=="_adb._tcp" || $2=="_adb-tls-connect._tcp" {print $3}' | sort -u | head -2 | tr '\n' ' ')
        fi
        case "$DEVICE" in
            '')       die "no device. Set DEVICE=<ip>:<port> or connect one first" ;;
            *' '*' ') die "several devices found — set DEVICE to one of: $DEVICE" ;;
            *)        DEVICE=${DEVICE% } ;;
        esac
    fi
    # A dropped device leaves a stale offline transport that `adb connect` reports as
    # already-connected, so the next `adb shell` fails. Tear it down and retry.
    i=0
    while :; do
        "$ADB" connect "$DEVICE" >/dev/null 2>&1 || true
        sh_ true >/dev/null 2>&1 && break
        i=$((i + 1))
        [ "$i" -lt 3 ] || die "no shell on $DEVICE after $i attempts — check ADB debugging, authorisation, and that the device is awake"
        "$ADB" disconnect "$DEVICE" >/dev/null 2>&1 || true
        sleep 2
    done
}

# The TV's state directory is keyed by its serial number, so each TV keeps its own record.
load_state() {
    SERIAL=$(dev getprop ro.serialno) || die "could not read the serial number from $DEVICE"
    case $SERIAL in
        ''|*[!A-Za-z0-9_.-]*) die "$DEVICE reports a serial number this tool cannot use as a name: '$SERIAL'" ;;
    esac
    BUILD=$(dev getprop ro.build.fingerprint) || die "could not read the firmware build from $DEVICE"
    STATE="$STATE_ROOT/$PROFILE/$SERIAL"
    BASELINE="$STATE/baseline.txt"; APPLIED="$STATE/applied.txt"; SETTINGS_FILE="$STATE/settings.txt"
    migrate_legacy
}

# Before 0.1.0 the state lived in backups/<profile>/ inside the clone, with the serial in serial.txt.
# Move it the first time its TV is seen, so nothing recorded is lost; the oldest snapshot becomes
# the baseline.
migrate_legacy() {
    names=$PROFILE
    if [ "$PROFILE" = firetv-stick-4k-max-2023 ]; then names="firetv-stick-hd $PROFILE"; fi
    for name in $names; do
        old="$HERE/backups/$name"
        [ -d "$old" ] || continue
        case $(cat "$old/serial.txt" 2>/dev/null || true) in
            "$SERIAL") ;;
            '') echo "note: $old has no serial.txt; if it belongs to this TV, move its files to $STATE" >&2; continue ;;
            *) continue ;;
        esac
        if [ -e "$STATE" ]; then echo "note: left $old alone: $STATE already exists" >&2; continue; fi
        if [ -n "$DRY_RUN" ]; then
            echo "note: a real run moves this TV's state from $old to $STATE; reading it there for now" >&2
            STATE=$old; BASELINE="$old/latest.txt"; APPLIED="$old/applied.txt"; SETTINGS_FILE="$old/settings.txt"
            return 0
        fi
        mkdir -p "$STATE"
        for f in "$old"/* "$old"/.[!.]*; do
            if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
            case ${f##*/} in
                latest.txt|serial.txt) rm -f "$f" ;;
                state-*) mv "$f" "$STATE/snapshot-${f##*/state-}" ;;
                *) mv "$f" "$STATE/" ;;
            esac
        done
        for f in "$STATE"/snapshot-*; do
            if [ -e "$f" ]; then cp "$f" "$BASELINE"; fi
            break
        done
        rmdir "$old" "$HERE/backups" 2>/dev/null || true
        echo "moved this TV's state from $old to $STATE" >&2
    done
}

# DEVICE is an IP, which DHCP can reassign. A TV this profile has not been used on is refused unless
# --new-device says it is meant, so the next TV to get that address is not changed by mistake.
check_known() {
    if [ -d "$STATE" ] || [ -n "$NEW_DEVICE" ]; then return 0; fi
    known=
    for d in "$STATE_ROOT/$PROFILE"/*/; do
        if [ -d "$d" ]; then known="$known $(basename "$d")"; fi
    done
    [ -z "$known" ] || die "this TV (serial $SERIAL) is new to profile $PROFILE, which has been used on:$known. If DEVICE points at the wrong TV, fix that; for a second TV of this model, add --new-device"
}

# Package lists made on another device are how playback gets broken, so changes need the device the
# profile was built for; --force is for someone who has compared the profile with this TV.
check_model() {
    got=$(dev getprop ro.product.device) || die "could not read ro.product.device from $DEVICE"
    if [ "$got" != "$device" ]; then
        [ -n "$FORCE" ] || die "this TV is '$got', but profile $PROFILE was built for '$device'. Another device's package list can break playback: compare first with '$0 --device $PROFILE verify', and add --force only if the profile fits this TV"
        echo "WARN this TV is '$got', profile $PROFILE was built for '$device' (--force)" >&2
    fi
    firmware_warnings >&2
}

# A profile was checked on one firmware. Another Android release, or a build that changed since the
# first backup, can rename packages or bring them back.
firmware_warnings() {
    if [ -n "$android" ]; then
        rel=$(dev getprop ro.build.version.release) || die "could not read the Android release from $DEVICE"
        if [ "$rel" != "$android" ]; then
            echo "WARN this TV runs Android $rel; profile $PROFILE was verified on Android $android — check its lists with verify"
        fi
    fi
    if [ -s "$STATE/build.txt" ] && [ "$(cat "$STATE/build.txt")" != "$BUILD" ]; then
        echo "WARN the firmware changed since this TV's first backup ($(cat "$STATE/build.txt") -> $BUILD): packages may have come back or been renamed"
    fi
}

# One line per run that changes something, in the TV's state directory.
log() { if [ -d "$STATE" ]; then printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE/log.txt"; fi; }
on_exit() {
    rc=$?
    if [ -n "${tmp:-}" ]; then rm -rf "$tmp"; fi
    if [ -n "$LOGGING" ]; then log "$cmd: exit $rc"; fi
}

cmd_info() {
    echo "profile: $PROFILE ($model)"
    for k in ro.product.model ro.product.device ro.build.version.release ro.product.cpu.abilist ro.build.fingerprint; do
        v=$(dev getprop "$k") || die "could not read $k from $DEVICE"
        printf '  %-26s %s\n' "$k" "$v"
    done
    v=$(dev 'nproc; grep -E "MemTotal|MemAvailable" /proc/meminfo') || die "could not read cpu and memory from $DEVICE"
    printf '  %-26s %s\n' cpus "$(printf '%s\n' "$v" | head -1)"
    printf '%s\n' "$v" | sed -n 's/^\(Mem[A-Za-z]*\): *\(.*\)/  \1                   \2/p'
    list=$(pkg_list -d) || exit 1
    printf '  %-26s %s\n' "disabled packages" "$(printf '%s\n' "$list" | sed '/^$/d' | wc -l | tr -d ' ')"
}

cmd_backup() {
    list=$(pkg_list -d) || exit 1
    if [ -n "$DRY_RUN" ]; then
        echo "  would record $(printf '%s\n' "$list" | grep -c .) already-disabled packages in $STATE"
        return 0
    fi
    mkdir -p "$STATE"
    # The host's clock in UTC: the TV's may be wrong until it syncs, and its output is not trusted
    # for file names.
    f="$STATE/snapshot-$(date -u +%Y%m%d-%H%M%S).txt"
    { echo "# disabled on $BUILD"; printf '%s\n' "$list" | sed '/^$/d' | sort; } > "$f"
    # The first snapshot is the baseline and stays: one taken after debloat would list this tool's
    # own changes as the owner's, and restore would then leave them alone.
    if [ ! -f "$BASELINE" ]; then cp "$f" "$BASELINE"; echo "baseline: $BASELINE"; fi
    if [ ! -f "$STATE/build.txt" ]; then echo "$BUILD" > "$STATE/build.txt"; fi
    echo "backup: $f ($(grep -vc '^#' "$f") already-disabled packages)"
}

# A tier name that matches nothing would otherwise "disable 0, fail 0" and look like success.
check_tiers() {
    for t in "$@"; do
        conf_lines "$CONF" | awk -v t="$t" '$1 == t {found = 1} END {exit !found}' || {
            others=$(conf_lines "$CONF" | awk '{print $1}' | uniq \
                | while read -r x; do case " $tiers " in *" $x "*) ;; *) printf '%s ' "$x" ;; esac; done)
            die "unknown tier '$t'. $PROFILE tiers: $tiers (default); ${others% } (opt-in)"
        }
    done
}

cmd_debloat() {
    # shellcheck disable=SC2086  # deliberate word splitting into separate tier arguments
    if [ $# -eq 0 ]; then set -- $tiers; fi
    check_tiers "$@"
    if [ -z "$DRY_RUN" ]; then
        [ -f "$BASELINE" ] || cmd_backup
        touch "$APPLIED"
    fi
    off=$(pkg_list -d) || exit 1
    echo "tiers: $*"
    ok=0; already=0; fail=0
    for p in $(tier_pkgs "$@"); do
        # Already off, by this tool earlier or by the owner: nothing to do, and nothing to record.
        if printf '%s\n' "$off" | grep -qxF -- "$p"; then
            already=$((already + 1)); continue
        fi
        if [ -n "$DRY_RUN" ]; then echo "  would disable $p"; ok=$((ok + 1)); continue; fi
        if out=$(sh_ pm disable-user --user 0 "$p" 2>&1); then
            ok=$((ok + 1)); echo "  disabled $p"
            # Record what this tool actually turned off. Restoring from this list rather than
            # from packages.conf keeps working after the config is edited, and never re-enables
            # something the user had already disabled themselves.
            if ! grep -qxF -- "$p" "$BASELINE" && ! grep -qxF -- "$p" "$APPLIED"; then
                echo "$p" >> "$APPLIED"
            fi
        else
            rc=$?; fail=$((fail + 1)); echo "  FAILED   $p: $(reason "$out" "$rc")" >&2
            alive || die "lost the connection to $DEVICE; the $ok disabled so far are recorded — run debloat again when the TV is back"
        fi
    done
    if [ -n "$DRY_RUN" ]; then echo "would disable $ok, already off $already"; return 0; fi
    echo "disabled $ok, already off $already, failed $fail (restore list: $APPLIED)"
    [ "$fail" -eq 0 ]
}

# The original as recorded: shell-quoted since put_setting quotes it, a bare token in records
# written before that, or null/empty for "was unset".
restore_cmd() {
    case $3 in
        null|'') echo "settings delete $1 $2" ;;
        \'*\') inner=${3#\'}; inner=${inner%\'}
               case $(printf '%s' "$inner" | sed "s/'\\\\''//g") in *\'*) return 1 ;; esac
               echo "settings put $1 $2 $3" ;;
        *) is_tok "$3" || return 1; echo "settings put $1 $2 $(q "$3")" ;;
    esac
}

cmd_restore() {
    applied=$APPLIED
    [ -s "$applied" ] || [ -s "$SETTINGS_FILE" ] \
        || die "nothing to restore: no packages or settings recorded in $STATE"
    if [ -n "$DRY_RUN" ]; then
        if [ -s "$applied" ]; then
            while read -r p; do [ -z "$p" ] || echo "  would re-enable $p"; done < "$applied"
        fi
        if [ -s "$SETTINGS_FILE" ]; then
            while read -r ns key val old; do
                case $old in null|'') echo "  would unset $key" ;; *) echo "  would restore $key = $old" ;; esac
            done < "$SETTINGS_FILE"
        fi
        return 0
    fi
    gone=; left=0
    # Each list is rewritten with only what could not be undone, so a re-run picks up where this one
    # stopped and verify can still see it; a list goes only once it is empty.
    if [ -s "$applied" ]; then
        n=0; : > "$applied.left"
        while read -r p; do
            [ -n "$p" ] || continue
            if [ -z "$gone" ]; then
                if out=$(sh_ pm enable --user 0 "$p" 2>&1); then
                    echo "  enabled $p"; n=$((n + 1)); continue
                else
                    rc=$?
                    if alive; then echo "  FAILED  $p: $(reason "$out" "$rc")" >&2; else gone=1; fi
                fi
            fi
            echo "$p" >> "$applied.left"
        done < "$applied"
        k=$(grep -c . "$applied.left" || true)
        echo "re-enabled $n of $((n + k))"
        if [ "$k" -gt 0 ]; then mv "$applied.left" "$applied"; left=$((left + k)); else rm -f "$applied" "$applied.left"; fi
    fi
    if [ -s "$SETTINGS_FILE" ]; then
        echo "restoring settings:"
        : > "$SETTINGS_FILE.left"
        while read -r ns key val old; do
            [ -n "$key" ] || continue
            if [ -z "$gone" ]; then
                if ! c=$(restore_cmd "$ns" "$key" "$old"); then
                    echo "  FAILED   $key: the recorded original is not a value it can send back: $old" >&2
                elif out=$(sh_ "$c" 2>&1); then
                    case $old in null|'') echo "  unset    $key" ;; *) echo "  restored $key = $old" ;; esac
                    continue
                else
                    rc=$?
                    if alive; then echo "  FAILED   $key: $(reason "$out" "$rc")" >&2; else gone=1; fi
                fi
            fi
            echo "$ns $key $val $old" >> "$SETTINGS_FILE.left"
        done < "$SETTINGS_FILE"
        k=$(grep -c . "$SETTINGS_FILE.left" || true)
        if [ "$k" -gt 0 ]; then mv "$SETTINGS_FILE.left" "$SETTINGS_FILE"; left=$((left + k)); else rm -f "$SETTINGS_FILE" "$SETTINGS_FILE.left"; fi
    fi
    [ -z "$gone" ] || die "lost the connection to $DEVICE; $left entries are still recorded — run restore again when the TV is back"
    if [ "$left" -gt 0 ]; then
        echo "error: $left entries could not be restored and are still recorded; fix the cause above and run restore again" >&2
        return 1
    fi
}

cmd_tune() {
    fail=0
    # Fed by redirect, not a pipe, so the failure count survives the loop.
    while read -r ns key value _; do
        [ -n "$key" ] || continue
        if ! put_setting "$ns" "$key" "$value"; then
            fail=$((fail + 1))
            alive || die "lost the connection to $DEVICE; the settings written so far are recorded"
        fi
    done <<EOF
$SETTINGS
EOF
    if [ -n "$DRY_RUN" ]; then echo "  would trim caches"
    elif sh_ pm trim-caches 4G >/dev/null 2>&1; then echo "  caches trimmed"
    else echo "  trim-caches unavailable"
    fi
    [ "$fail" -eq 0 ]
}
cmd_perf() { cmd_tune "$@"; }

cmd_apps() {
    if [ -n "$DRY_RUN" ]; then
        while IFS='|' read -r name url _; do
            [ -z "$name" ] || echo "  would install $name from $url"
        done <<EOF
$APPS
EOF
        return 0
    fi
    # Removed by on_exit; an interrupt ends the run through the same path, so the download goes too.
    tmp=$(mktemp -d)
    fail=0
    # Fed by redirect, not a pipe: a checksum mismatch must abort the script, not a subshell.
    while IFS='|' read -r name url want; do
        [ -n "$name" ] || continue
        if [ "$url" = play ]; then
            if sh_ am start -a android.intent.action.VIEW -d "$(q "market://details?id=$name")" >/dev/null 2>&1; then
                echo "  $name: Play Store listing opened on the TV — press Install with the remote"
            else
                echo "  FAILED   $name: could not open the Play Store" >&2; fail=$((fail + 1))
            fi
            continue
        fi
        echo "  fetching $name"
        curl -fsSL -o "$tmp/$name.apk" "$url" || die "download failed: $name"
        got=$(sha256 "$tmp/$name.apk")
        [ "$got" = "$want" ] || die "checksum mismatch for $name — refusing to install"
        if out=$(timed 900 "$ADB" -s "$DEVICE" install -r "$tmp/$name.apk" 2>&1 </dev/null); then
            echo "  installed $name"
        else
            rc=$?; echo "  FAILED   $name: $(reason "$out" "$rc" 900)" >&2; fail=$((fail + 1))
        fi
    done <<EOF
$APPS
EOF
    [ "$fail" -eq 0 ]
}

cmd_verify() {
    rc=0
    echo "--- device props ---"
    for kv in $props; do
        k=${kv%%=*}; want=${kv#*=}
        v=$(dev getprop "$k") || die "could not read $k from $DEVICE"
        if [ "$v" = "$want" ]; then echo "  ok   $k=$v"; else echo "  FAIL $k is '$v', expected '$want'"; rc=1; fi
    done

    echo "--- protected packages enabled ---"
    disabled=$(pkg_list -d) || exit 1
    bad=0
    for p in $PROTECTED; do
        if printf '%s\n' "$disabled" | grep -qxF -- "$p"; then
            echo "  FAIL $p is disabled"; bad=$((bad + 1)); rc=1
        fi
    done
    got=$(dev getprop ro.product.device) || die "could not read ro.product.device from $DEVICE"
    if [ "$got" != "$device" ]; then
        echo "  WARN device is '$got', profile $PROFILE was built for '$device' — review it first"
    fi
    firmware_warnings | sed 's/^/  /'
    if [ "$bad" -eq 0 ]; then echo "  ok   none disabled"; fi

    # Drift check: some firmware re-enables packages on boot, so "nothing is broken" is not
    # the same question as "everything we turned off is still off".
    echo "--- packages this tool disabled are still disabled ---"
    applied=$APPLIED
    if [ -s "$applied" ]; then
        back=
        while read -r p; do
            [ -n "$p" ] || continue
            if ! printf '%s\n' "$disabled" | grep -qxF -- "$p"; then
                echo "  FAIL $p was re-enabled"; back="$back $p"; rc=1
            fi
        done < "$applied"
        if [ -z "$back" ]; then
            echo "  ok   all $(grep -c . "$applied") still disabled"
        else
            # Name the tiers: vizzini, say, sits in the opt-in alexa tier, which plain `debloat` skips.
            again=$(for p in $back; do conf_lines "$CONF" | awk -v p="$p" '$2 == p {print $1; exit}'; done | sort -u | tr '\n' ' ')
            echo "  re-run: $0 debloat ${again% }"
        fi
    else
        echo "  --   nothing recorded: debloat has not run on this TV, or restore cleared it"
    fi

    echo "--- settings still applied ---"
    if [ -s "$SETTINGS_FILE" ]; then
        drift=0
        while read -r ns key want _; do
            [ -n "$key" ] || continue
            got=$(dev settings get "$ns" "$key") || die "could not read $ns $key from $DEVICE"
            if [ "$got" != "$want" ]; then
                case $key in
                    private_dns_*) again="$0 dns" ;;
                    screen_off_timeout|sleep_timeout) again="$0 sleep" ;;
                    *) again="$0 tune" ;;
                esac
                echo "  FAIL $key is '$got', expected '$want' — re-run: $again"; drift=$((drift + 1)); rc=1
            fi
        done < "$SETTINGS_FILE"
        if [ "$drift" -eq 0 ]; then
            echo "  ok   all $(grep -c . "$SETTINGS_FILE") settings hold"
        fi
    else
        echo "  --   nothing recorded: tune, dns and sleep have not run on this TV, or restore cleared it"
    fi

    echo "--- sideloaded apps present ---"
    installed=$(pkg_list -3) || exit 1
    while IFS='|' read -r pkg _ _; do
        [ -n "$pkg" ] || continue
        if printf '%s\n' "$installed" | grep -qxF -- "$pkg"; then
            echo "  ok   $pkg"
        else
            echo "  --   $pkg not installed (run: $0 apps)"
        fi
    done <<EOF
$APPS
EOF

    echo "--- home screen resolves ---"
    home=$(home_activity) || die "could not read the launcher from $DEVICE"
    ok=0
    for l in $launcher; do
        case "$home" in "$l"/*) ok=1 ;; esac
    done
    if [ "$ok" -eq 1 ]; then
        echo "  ok   $home"
    else
        echo "  FAIL home is '${home:-none}', expected one of: $launcher"; rc=1
    fi

    if [ -n "$DEEP" ]; then
        echo "--- launching media apps (takes over the TV) ---"
        present=''
        for p in $MEDIA_APPS; do
            list=$(pkg_list "$p") || exit 1
            if printf '%s\n' "$list" | grep -qxF -- "$p"; then present="$present $p"; fi
        done
        if [ -z "$present" ]; then echo "  --   none of the known media apps are installed"; fi
        for p in $present; do
            start_pkg "$p" || true
            sleep 4
            if sh_ pidof "$p" >/dev/null 2>&1; then echo "  ok   $p"; else echo "  FAIL $p did not start"; rc=1; fi
            sh_ am force-stop "$p" >/dev/null 2>&1 || true
        done
        sh_ am start -c android.intent.category.HOME -a android.intent.action.MAIN >/dev/null 2>&1 || true
    fi
    return $rc
}

cmd_status() { list=$(pkg_list -d) || exit 1; printf '%s\n' "$list" | sed '/^$/d' | sort; }

# Two independent timers: screen_off_timeout blanks the display, sleep_timeout suspends the
# device. Setting only one leaves the other to cut in first.
cmd_sleep() {
    case "${1:-show}" in
        show)
            echo "  screen_off_timeout $(sh_ settings get system screen_off_timeout | tr -d '\r') ms"
            echo "  sleep_timeout      $(sh_ settings get secure sleep_timeout | tr -d '\r') ms"
            return 0
            ;;
        never) ms=2147483647 ;;
        # Android reads both timers as a 32-bit millisecond count; 0 has no documented meaning.
        *)     valid_minutes "$1" || die "sleep takes 1 to 35791 minutes, never or show"
               ms=$(($1 * 60000)) ;;
    esac
    put_setting system screen_off_timeout "$ms"
    put_setting secure sleep_timeout "$ms"
}

# Fire OS hides the Private DNS menu but the Android resolver still honours the setting, which
# makes DNS-over-TLS the only on-device way to block an OTA client that cannot be disabled.
cmd_dns() {
    case "${1:-show}" in
        show)
            sh_ 'settings get global private_dns_mode; settings get global private_dns_specifier'
            sh_ dumpsys connectivity | grep -oE 'UsePrivateDns: [a-z]+|ValidatedPrivateDnsAddresses: \[[^]]*\]' | sort -u
            ;;
        off)
            put_setting global private_dns_mode off
            ;;
        # Android's own default: DNS-over-TLS whenever the network's resolver offers it.
        auto)
            put_setting global private_dns_mode opportunistic
            ;;
        *)
            is_host "$1" || die "Private DNS needs a hostname such as dns.example.com, not '$1'"
            put_setting global private_dns_specifier "$1"
            put_setting global private_dns_mode hostname
            ;;
    esac
}

# Google TV has no menu for changing the launcher; the package manager does it without root.
cmd_home() {
    case "${1:-show}" in
        show) home_activity || die "could not read the launcher from $DEVICE" ;;
        *)
            is_pkg "$1" || die "not a package name: '$1'"
            list=$(dev 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME --user 0') \
                || die "could not list the launchers on $DEVICE"
            comp=$(printf '%s\n' "$list" | awk -v p="$1/" 'index($1, p) == 1 {print $1; exit}')
            [ -n "$comp" ] || die "$1 is not installed or has no HOME activity"
            if [ -n "$DRY_RUN" ]; then echo "  would set home to $comp"; return 0; fi
            sh_ cmd package set-home-activity "$comp" --user 0 >/dev/null 2>&1 || die "could not set $comp as home"
            echo "home = $comp"
            ;;
    esac
}

# F-Droid ships no LEANBACK_LAUNCHER icon, so it never appears on a TV home screen.
cmd_launch() {
    start_pkg "$1" || die "could not start $1"
    echo "started $1"
}

usage() {
    cat <<EOF
usage: $(basename "$0") [options] <command> [arguments]

  info                  device summary
  backup                snapshot which packages are already disabled
  debloat [tiers...]    disable packages (default tiers come from the profile)
  restore               undo this tool: re-enable its packages and roll settings back
  tune                  apply the profile's settings.conf, trim caches ('perf' is an old name)
  apps                  sideload the profile's apps.conf (checksum-pinned)
  verify                DRM props, protected packages, drift, launcher
  status                list currently disabled packages
  launch <package>      start an app that has no home-screen icon (e.g. F-Droid)
  home [package|show]   show or set the launcher
  dns [host|off|auto|show]    Private DNS: a DNS-over-TLS hostname, off, or Android's default
  sleep [minutes|never|show]  display-off and device-sleep timers, both at once

options, anywhere on the line:
  --device <profile>    use devices/<profile> instead of matching the TV's model
  --deep                verify: also launch each installed media app (takes over the TV)
  --new-device          start a separate record for a second TV of the same model
  --force               change a TV that is not the device its profile was built for
  --dry-run             show what a command would change; nothing on the TV or in its state changes
  -h, --help            this text; never touches the TV
  --version             print the version

profiles: $(profiles)
state: $STATE_ROOT/<profile>/<serial>/
env: DEVICE           ip:port or serial (auto-detected when exactly one is attached or on mDNS)
     ADB              path to adb
     TWEAK_PROFILE    same as --device
     TWEAK_STATE      where the per-TV state lives (default above)
     TWEAK_CONF       another packages.conf
     TWEAK_MEDIA_APPS replace the profile's media_apps
     TWEAK_TIMEOUT    seconds before an adb call is given up (default 60)
EOF
}

# Sourcing with TWEAK_LIB=1 loads the functions without dispatching, for test.sh.
if [ -n "${TWEAK_LIB:-}" ]; then return 0; fi

# Options may sit anywhere, and asking for help never reaches the TV: `dns --help` used to set the
# Private DNS hostname to "--help".
cmd=; args=; DEEP=
while [ $# -gt 0 ]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --version) echo "tweak $VERSION"; exit 0 ;;
        --device)  [ $# -ge 2 ] || usage_error "--device needs a profile name"; PROFILE=$2; shift ;;
        --device=*) PROFILE=${1#--device=} ;;
        --deep)    DEEP=1 ;;
        --new-device) NEW_DEVICE=1 ;;
        --force)   FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -*)        usage_error "unknown option '$1'" ;;
        *)  if [ -z "$cmd" ]; then cmd=$1
            elif is_tok "$1"; then args="$args $1"
            else usage_error "invalid argument '$1'"
            fi ;;
    esac
    shift
done
[ -n "$cmd" ] || { usage >&2; exit 2; }
if [ -n "$PROFILE" ] && ! is_profile "$PROFILE"; then usage_error "invalid profile name '$PROFILE'"; fi
if [ -n "$DEEP" ] && [ "$cmd" != verify ]; then usage_error "--deep only applies to verify"; fi
case $DRY_RUN:$cmd in
    1:info|1:verify|1:status|1:launch|1:help) usage_error "--dry-run applies to commands that change something" ;;
esac
# shellcheck disable=SC2086  # every argument passed is_tok: no spaces, no glob characters
set -- $args
# Arguments are checked here, before connecting, so a typo costs nothing on the TV.
case $cmd in
    help) usage; exit 0 ;;
    info|backup|restore|tune|perf|apps|verify|status)
        [ $# -eq 0 ] || usage_error "$cmd takes no arguments" ;;
    debloat) ;;
    launch)
        if [ $# -ne 1 ] || ! is_pkg "$1"; then usage_error "launch takes one package name"; fi ;;
    home)
        if [ $# -gt 1 ] || { [ "${1:-show}" != show ] && ! is_pkg "$1"; }; then
            usage_error "home takes a package name, or show"
        fi ;;
    dns)
        [ $# -le 1 ] || usage_error "dns takes one hostname, off, auto or show"
        case ${1:-show} in
            show|off|auto) ;;
            *) is_host "$1" || usage_error "Private DNS needs a hostname such as dns.example.com, not '$1'" ;;
        esac ;;
    sleep)
        [ $# -le 1 ] || usage_error "sleep takes 1 to 35791 minutes, never or show"
        case ${1:-show} in
            show|never) ;;
            *) valid_minutes "$1" || usage_error "sleep takes 1 to 35791 minutes, never or show" ;;
        esac ;;
    *) usage_error "unknown command '$cmd'" ;;
esac
connect; load_profile; load_state
trap on_exit EXIT
trap 'exit 130' INT TERM HUP
case $cmd in
    info|verify|status|launch) ;;
    *)  check_known
        case $cmd in restore|backup) ;; *) check_model ;; esac
        if [ -n "$DRY_RUN" ]; then
            echo "dry run: nothing on the TV or in $STATE changes"
        else
            mkdir -p "$STATE"; LOGGING=1
            log "$cmd$args — tweak $VERSION, $BUILD"
            echo "state: $STATE"
        fi ;;
esac
"cmd_$cmd" "$@"
