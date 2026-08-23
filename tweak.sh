#!/bin/sh
# tweak — debloat and tune an Android TV device over ADB. No root required.
# Everything device-specific lives in devices/<profile>/; the README lists the verified devices.
set -eu

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
PROFILE=${PROFILE:-}
BACKUP_ROOT=${BACKUP_ROOT:-$HERE/backups}

die() { echo "error: $*" >&2; exit 1; }
profiles() { for d in "$HERE"/devices/*/; do basename "$d"; done | tr '\n' ' '; }

# stdin is closed: `adb shell` otherwise consumes the caller's stdin, which silently
# swallows the rest of the input in `while read ... done < file` loops.
sh_() { "$ADB" -s "$DEVICE" shell "$@" </dev/null; }
kept() { printf '%s\n' "$KEEP" | grep -qx "$1"; }

# `--device <name>` or PROFILE= picks devices/<name>. Otherwise ro.product.model is matched
# against every device.conf, which needs a connected device first.
load_profile() {
    if [ -z "$PROFILE" ]; then
        m=$(sh_ getprop ro.product.model | tr -d '\r')
        for d in "$HERE"/devices/*/; do
            if grep -qxF "model=\"$m\"" "$d/device.conf" 2>/dev/null; then
                PROFILE=$(basename "$d"); break
            fi
        done
        [ -n "$PROFILE" ] || die "no profile in devices/ matches model '$m' — pass --device <name>"
    fi
    PROFILE_DIR="$HERE/devices/$PROFILE"
    [ -f "$PROFILE_DIR/device.conf" ] \
        || die "unknown profile '$PROFILE'; available: $(profiles)"
    model=; device=; tiers=; launcher=; media_apps=; props=
    # shellcheck source=/dev/null
    . "$PROFILE_DIR/device.conf"
    CONF=${CONF:-$PROFILE_DIR/packages.conf}
    # Protected packages are enforced independently of packages.conf so a bad edit cannot brick
    # playback.
    KEEP=$(grep -v '^#' "$PROFILE_DIR/keep.conf" || true)
    APPS=$(grep -v '^#' "$PROFILE_DIR/apps.conf" || true)
    SETTINGS=$(sed 's/#.*//' "$PROFILE_DIR/settings.conf")
    MEDIA_APPS=${MEDIA_APPS:-$media_apps}
    BACKUP_DIR=${BACKUP_DIR:-$BACKUP_ROOT/$PROFILE}
    SETTINGS_FILE=${SETTINGS_FILE:-$BACKUP_DIR/settings.txt}
}

# Every setting this tool writes is recorded so `verify` can prove it survived a reboot.
put_setting() {
    old=$(sh_ settings get "$1" "$2" | tr -d '\r')
    if ! sh_ settings put "$1" "$2" "$3" >/dev/null 2>&1; then
        echo "  FAILED $2"; return 0
    fi
    mkdir -p "$BACKUP_DIR"
    # Keep the first original ever seen: re-running tune must not record our own value as the
    # thing to roll back to.
    prev=$(awk -v n="$1" -v k="$2" '$1==n && $2==k {print $4}' "$SETTINGS_FILE" 2>/dev/null || true)
    if [ -n "$prev" ]; then old=$prev; fi
    { grep -v "^$1 $2 " "$SETTINGS_FILE" 2>/dev/null || true; echo "$1 $2 $3 $old"; } > "$SETTINGS_FILE.tmp"
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    echo "  $2 = $3"
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
        awk -v t="$t" '$1==t && $2 ~ /^[a-z]/ {print $2}' "$CONF"
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
    pref=$(sh_ dumpsys package preferred-xml | tr -d '\r' | awk '
        /<item name="/ { sub(/.*<item name="/, ""); sub(/".*/, ""); item = $0 }
        /android\.intent\.category\.HOME/ && item != "" { print item; exit }')
    if [ -n "$pref" ]; then echo "$pref"; return 0; fi
    sh_ 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME --user 0' \
        | tr -d '\r' | tail -1
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

# DEVICE is an IP, which DHCP can reassign. `backup` pins the serial of the device a profile was
# first used on; refuse to run `pm` against anything else.
check_serial() {
    want=${EXPECT_SERIAL:-$(cat "$BACKUP_DIR/serial.txt" 2>/dev/null || true)}
    [ -n "$want" ] || return 0
    got=$(sh_ getprop ro.serialno | tr -d '\r')
    [ "$got" = "$want" ] \
        || die "$DEVICE reports serial '$got', expected '$want' (profile $PROFILE)"
}

cmd_info() {
    echo "profile: $PROFILE ($model)"
    sh_ 'getprop ro.product.model; getprop ro.product.device; getprop ro.build.version.release; getprop ro.product.cpu.abilist; nproc'
    echo "--- memory ---"; sh_ 'grep -E "MemTotal|MemAvailable" /proc/meminfo'
    echo "--- disabled packages: "; sh_ 'pm list packages -d' | wc -l
}

cmd_backup() {
    mkdir -p "$BACKUP_DIR"
    stamp=$(sh_ date +%Y%m%d-%H%M%S | tr -d '\r')
    f="$BACKUP_DIR/state-$stamp.txt"
    {
        echo "# disabled at backup time"
        sh_ 'pm list packages -d' | sed 's/^package://' | tr -d '\r' | sort
    } > "$f"
    ln -sf "$(basename "$f")" "$BACKUP_DIR/latest.txt"
    [ -s "$BACKUP_DIR/serial.txt" ] || sh_ getprop ro.serialno | tr -d '\r' > "$BACKUP_DIR/serial.txt"
    echo "backup: $f ($(grep -vc '^#' "$f") already-disabled packages)"
}

cmd_debloat() {
    # shellcheck disable=SC2086  # deliberate word splitting into separate tier arguments
    if [ $# -eq 0 ]; then set -- $tiers; fi
    [ -f "$BACKUP_DIR/latest.txt" ] || cmd_backup
    prior="$BACKUP_DIR/$(readlink "$BACKUP_DIR/latest.txt")"
    applied="$BACKUP_DIR/applied.txt"
    touch "$applied"
    echo "tiers: $*"
    ok=0; fail=0
    for p in $(tier_pkgs "$@"); do
        if sh_ pm disable-user --user 0 "$p" >/dev/null 2>&1; then
            ok=$((ok + 1)); echo "  disabled $p"
            # Record what this tool actually turned off. Restoring from this list rather than
            # from packages.conf keeps working after the config is edited, and never re-enables
            # something the user had already disabled themselves.
            if ! grep -qx "$p" "$prior" && ! grep -qx "$p" "$applied"; then
                echo "$p" >> "$applied"
            fi
        else
            fail=$((fail + 1)); echo "  FAILED   $p"
        fi
    done
    echo "disabled $ok, failed $fail (restore list: $applied)"
}

cmd_restore() {
    applied="$BACKUP_DIR/applied.txt"
    [ -s "$applied" ] || die "nothing to restore: $applied is missing or empty"
    n=0
    while read -r p; do
        [ -n "$p" ] || continue
        if sh_ pm enable "$p" >/dev/null 2>&1; then
            echo "  enabled $p"; n=$((n + 1))
        else
            echo "  FAILED  $p"
        fi
    done < "$applied"
    echo "re-enabled $n of $(wc -l < "$applied" | tr -d ' ')"

    [ -s "$SETTINGS_FILE" ] || return 0
    echo "restoring settings:"
    while read -r ns key _ old; do
        [ -n "$key" ] || continue
        if [ "$old" = null ] || [ -z "$old" ]; then
            sh_ settings delete "$ns" "$key" >/dev/null 2>&1 && echo "  unset    $key" || echo "  FAILED   $key"
        else
            sh_ settings put "$ns" "$key" "$old" >/dev/null 2>&1 && echo "  restored $key = $old" || echo "  FAILED   $key"
        fi
    done < "$SETTINGS_FILE"
    rm -f "$SETTINGS_FILE"
}

cmd_tune() {
    printf '%s\n' "$SETTINGS" | while read -r ns key value _; do
        [ -n "$key" ] || continue
        put_setting "$ns" "$key" "$value"
    done
    sh_ pm trim-caches 4G >/dev/null 2>&1 && echo "  caches trimmed" || echo "  trim-caches unavailable"
}
cmd_perf() { cmd_tune "$@"; }

cmd_apps() {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # Fed by redirect, not a pipe: a checksum mismatch must abort the script, not a subshell.
    while IFS='|' read -r name url want; do
        [ -n "$name" ] || continue
        if [ "$url" = play ]; then
            sh_ am start -a android.intent.action.VIEW -d "market://details?id=$name" >/dev/null 2>&1 \
                && echo "  $name: Play Store listing opened on the TV — press Install with the remote" \
                || echo "  FAILED to open the Play Store for $name"
            continue
        fi
        echo "  fetching $name"
        curl -fsSL -o "$tmp/$name.apk" "$url" || die "download failed: $name"
        got=$(sha256 "$tmp/$name.apk")
        [ "$got" = "$want" ] || die "checksum mismatch for $name — refusing to install"
        "$ADB" -s "$DEVICE" install -r "$tmp/$name.apk" >/dev/null 2>&1 </dev/null \
            && echo "  installed $name" || echo "  FAILED to install $name"
    done <<EOF
$APPS
EOF
}

cmd_verify() {
    rc=0
    echo "--- device props ---"
    for kv in $props; do
        k=${kv%%=*}; want=${kv#*=}
        v=$(sh_ getprop "$k" | tr -d '\r')
        if [ "$v" = "$want" ]; then echo "  ok   $k=$v"; else echo "  FAIL $k is '$v', expected '$want'"; rc=1; fi
    done

    echo "--- protected packages enabled ---"
    disabled=$(sh_ 'pm list packages -d' | sed 's/^package://' | tr -d '\r')
    bad=0
    for p in $KEEP $MEDIA_APPS; do
        if printf '%s\n' "$disabled" | grep -qx "$p"; then
            echo "  FAIL $p is disabled"; bad=$((bad + 1)); rc=1
        fi
    done
    got=$(sh_ getprop ro.product.device | tr -d '\r')
    if [ "$got" != "$device" ]; then
        echo "  WARN device is '$got', profile $PROFILE was built for '$device' — review it first"
    fi
    if [ "$bad" -eq 0 ]; then echo "  ok   none disabled"; fi

    # Drift check: some firmware re-enables packages on boot, so "nothing is broken" is not
    # the same question as "everything we turned off is still off".
    echo "--- packages this tool disabled are still disabled ---"
    applied="$BACKUP_DIR/applied.txt"
    if [ -s "$applied" ]; then
        back=0
        while read -r p; do
            [ -n "$p" ] || continue
            if ! printf '%s\n' "$disabled" | grep -qx "$p"; then
                echo "  FAIL $p was re-enabled"; back=$((back + 1)); rc=1
            fi
        done < "$applied"
        if [ "$back" -eq 0 ]; then
            echo "  ok   all $(wc -l < "$applied" | tr -d ' ') still disabled"
        else
            echo "  $back re-enabled — re-run: $(basename "$0") debloat"
        fi
    else
        echo "  skip no applied.txt yet"
    fi

    echo "--- settings still applied ---"
    if [ -s "$SETTINGS_FILE" ]; then
        drift=0
        while read -r ns key want _; do
            [ -n "$key" ] || continue
            got=$(sh_ settings get "$ns" "$key" | tr -d '\r')
            if [ "$got" != "$want" ]; then
                echo "  FAIL $key is '$got', expected '$want'"; drift=$((drift + 1)); rc=1
            fi
        done < "$SETTINGS_FILE"
        if [ "$drift" -eq 0 ]; then
            echo "  ok   all $(wc -l < "$SETTINGS_FILE" | tr -d ' ') settings hold"
        fi
    else
        echo "  skip no settings recorded yet"
    fi

    echo "--- sideloaded apps present ---"
    installed=$(sh_ 'pm list packages -3' | sed 's/^package://' | tr -d '\r')
    while IFS='|' read -r pkg _ _; do
        [ -n "$pkg" ] || continue
        if printf '%s\n' "$installed" | grep -qx "$pkg"; then
            echo "  ok   $pkg"
        else
            echo "  --   $pkg not installed (run: $(basename "$0") apps)"
        fi
    done <<EOF
$APPS
EOF

    echo "--- home screen resolves ---"
    home=$(home_activity)
    ok=0
    for l in $launcher; do
        case "$home" in "$l"/*) ok=1 ;; esac
    done
    if [ "$ok" -eq 1 ]; then
        echo "  ok   $home"
    else
        echo "  FAIL home is '${home:-none}', expected one of: $launcher"; rc=1
    fi

    if [ "${1:-}" = "--deep" ]; then
        echo "--- launching media apps (takes over the TV) ---"
        present=''
        for p in $MEDIA_APPS; do
            if sh_ "pm list packages $p" | grep -q "package:$p"; then present="$present $p"; fi
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

cmd_status() { sh_ 'pm list packages -d' | sed 's/^package://' | tr -d '\r' | sort; }

# Two independent timers: screen_off_timeout blanks the display, sleep_timeout suspends the
# device. Setting only one leaves the other to cut in first.
cmd_sleep() {
    case "${1:-show}" in
        show)
            echo "  screen_off_timeout $(sh_ settings get system screen_off_timeout | tr -d '\r') ms"
            echo "  sleep_timeout      $(sh_ settings get secure sleep_timeout | tr -d '\r') ms"
            return 0
            ;;
        never)       ms=2147483647 ;;
        ''|*[!0-9]*) die "usage: sleep <minutes|never|show>" ;;
        *)           ms=$(($1 * 60000)) ;;
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
        *)
            put_setting global private_dns_specifier "$1"
            put_setting global private_dns_mode hostname
            ;;
    esac
}

# Google TV has no menu for changing the launcher; the package manager does it without root.
cmd_home() {
    case "${1:-show}" in
        show) home_activity ;;
        *)
            comp=$(sh_ 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME --user 0' \
                | tr -d '\r' | awk -v p="$1/" 'index($1, p) == 1 {print $1; exit}')
            [ -n "$comp" ] || die "$1 is not installed or has no HOME activity"
            sh_ cmd package set-home-activity "$comp" --user 0 >/dev/null 2>&1 || die "could not set $comp as home"
            echo "home = $comp"
            ;;
    esac
}

# F-Droid ships no LEANBACK_LAUNCHER icon, so it never appears on a TV home screen.
cmd_launch() {
    [ $# -eq 1 ] || die "usage: launch <package>"
    start_pkg "$1" || die "could not start $1"
    echo "started $1"
}

usage() {
    cat <<EOF
usage: $(basename "$0") [--device <profile>] <command>

  info                 device summary
  backup               snapshot which packages are already disabled
  debloat [tiers...]   disable packages (default tiers come from the profile)
  restore              undo this tool: re-enable its packages and roll settings back
  tune                 apply the profile's settings.conf, trim caches
  apps                 sideload the profile's apps.conf (checksum-pinned)
  verify [--deep]      DRM props, protected packages, drift, launcher; --deep also launches media apps
  status               list currently disabled packages
  launch <package>     start an app that has no home-screen icon (e.g. F-Droid)
  home [package]       show or set the launcher
  dns [host|off|show]  system-wide DNS-over-TLS
  sleep <min|never>    display-off and device-sleep timers (both, or 'show')

profiles: $(profiles)
env: DEVICE (auto-detected when exactly one is attached or advertised over mDNS), ADB, PROFILE,
     CONF, BACKUP_DIR, SETTINGS_FILE
     EXPECT_SERIAL  override the serial that backup pins in backups/<profile>/serial.txt
EOF
}

# Sourcing with TWEAK_LIB=1 loads the functions without dispatching, for test.sh.
if [ -n "${TWEAK_LIB:-}" ]; then return 0; fi

if [ "${1:-}" = --device ]; then
    [ $# -ge 2 ] || { usage; exit 2; }
    PROFILE=$2; shift 2
fi
[ $# -ge 1 ] || { usage; exit 2; }
c=$1; shift
case "$c" in
    info|backup|debloat|restore|tune|perf|apps|verify|status|launch|home|dns|sleep) connect; load_profile; check_serial; "cmd_$c" "$@" ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
esac
