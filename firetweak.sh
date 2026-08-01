#!/bin/sh
# firetweak — debloat and tune an Amazon Fire TV Stick over ADB. No root required.
# Verified against: Fire TV Stick 4K Max (karat / AFTKRT), Fire OS 8.1.8.0, armeabi-v7a.
set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEVICE=${DEVICE:-}
ADB=${ADB:-adb}
CONF=${CONF:-$HERE/packages.conf}
BACKUP_DIR=${BACKUP_DIR:-$HERE/backups}
DEFAULT_TIERS="ads promo ota cruft"

# Packages that must never be disabled: DRM, account/licensing, remote input, video apps.
# Enforced independently of packages.conf so a bad edit cannot brick playback.
KEEP='
android
com.amazon.ale
com.amazon.dcp
com.amazon.device.controllermanager
com.amazon.firebat
com.amazon.fireinputdevices
com.amazon.franktvinput
com.amazon.identity.auth.device.authorization
com.amazon.ssm
com.amazon.ssmsys
com.amazon.tcomm
com.amazon.tcomm.client
com.amazon.tv.ime
com.amazon.tv.intentsupport
com.amazon.tv.keypolicymanager
com.amazon.tv.launcher
com.amazon.tv.routing
com.amazon.tv.settings.core
com.amazon.tv.settings.v2
com.amazon.webview.chromium
com.android.systemui
com.esaba.downloader
com.mediatek.tvinput
'

# Candidates for the `verify --deep` smoke test; only the installed ones are launched.
MEDIA_APPS=${MEDIA_APPS:-'com.amazon.firebat com.netflix.ninja com.disney.disneyplus com.hbo.hbonow com.apple.atve.amazon.appletv org.xbmc.kodi com.amazon.avod com.wbd.stream com.spotify.tv.android'}

# Pinned sideload targets. Checksums recorded 2026-08-01; `apps` refuses on mismatch.
# Each carries armeabi-v7a code — this device is 32-bit and will reject arm64-only APKs.
APKS='
com.phlox.tvwebbrowser|https://github.com/truefedex/tv-bro/releases/download/v2.1.6/tvbro-2.1.6-generic-geckoExcluded.apk|d8634edfe8d94b4fb9a52005d68a090a7f1e85b7f39c2cf01a25dc9dd60942b2
dev.imranr.obtainium|https://github.com/ImranR98/Obtainium/releases/download/v1.6.10/app-armeabi-v7a-release.apk|2f4ff5227e486af985c665b6615a67effb498d6516662b98096bf1d0c43054cf
org.fdroid.fdroid|https://f-droid.org/repo/org.fdroid.fdroid_1023052.apk|985f5181d48bb6bafd54083a048b391271e0ab28385881cc41294fb01a222762
net.mullvad.mullvadvpn|https://github.com/mullvad/mullvadvpn-app/releases/download/android/2026.8/MullvadVPN-2026.8.apk|40b6d740ede6d806bc8849f831b53929e658db6f4325c773d064c601c31e4081
'

die() { echo "error: $*" >&2; exit 1; }

SETTINGS_FILE=${SETTINGS_FILE:-$BACKUP_DIR/settings.txt}

# Every setting this tool writes is recorded so `verify` can prove it survived a reboot.
put_setting() {
    old=$(sh_ settings get "$1" "$2" | tr -d '\r')
    if ! sh_ settings put "$1" "$2" "$3" >/dev/null 2>&1; then
        echo "  FAILED $2"; return 0
    fi
    mkdir -p "$BACKUP_DIR"
    # Keep the first original ever seen: re-running perf must not record our own value as the
    # thing to roll back to.
    prev=$(awk -v n="$1" -v k="$2" '$1==n && $2==k {print $4}' "$SETTINGS_FILE" 2>/dev/null || true)
    if [ -n "$prev" ]; then old=$prev; fi
    { grep -v "^$1 $2 " "$SETTINGS_FILE" 2>/dev/null || true; echo "$1 $2 $3 $old"; } > "$SETTINGS_FILE.tmp"
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    echo "  $2 = $3"
}
# stdin is closed: `adb shell` otherwise consumes the caller's stdin, which silently
# swallows the rest of the input in `while read ... done < file` loops.
sh_() { "$ADB" -s "$DEVICE" shell "$@" </dev/null; }
kept() { printf '%s\n' "$KEEP" | grep -qx "$1"; }

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

connect() {
    if [ -z "$DEVICE" ]; then
        DEVICE=$("$ADB" devices | awk '$2=="device" {print $1}' | head -2 | tr '\n' ' ')
        case "$DEVICE" in
            '')       die "no device. Set DEVICE=<ip>:5555 or connect one first" ;;
            *' '*' ') die "several devices attached — set DEVICE to one of: $DEVICE" ;;
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
        [ "$i" -lt 3 ] || die "no shell on $DEVICE after $i attempts — check ADB debugging, authorisation, and that the stick is awake"
        "$ADB" disconnect "$DEVICE" >/dev/null 2>&1 || true
        sleep 2
    done
    # DEVICE is an IP, which DHCP can reassign. Refuse to run `pm` against the wrong host.
    if [ -n "${EXPECT_SERIAL:-}" ]; then
        got=$(sh_ getprop ro.serialno | tr -d '\r')
        [ "$got" = "$EXPECT_SERIAL" ] \
            || die "$DEVICE reports serial '$got', expected '$EXPECT_SERIAL'"
    fi
}

cmd_info() {
    sh_ 'getprop ro.product.model; getprop ro.build.version.name; getprop ro.product.cpu.abilist; nproc'
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
    echo "backup: $f ($(grep -vc '^#' "$f") already-disabled packages)"
}

cmd_debloat() {
    # shellcheck disable=SC2086  # deliberate word splitting into separate tier arguments
    if [ $# -eq 0 ]; then set -- $DEFAULT_TIERS; fi
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

cmd_perf() {
    for k in window_animation_scale transition_animation_scale animator_duration_scale; do
        put_setting global "$k" 0.0
    done
    put_setting global ota_disable_automatic_update 1
    # No location provider on a mains-powered HDMI stick has a legitimate consumer.
    put_setting secure location_mode 0
    sh_ pm trim-caches 4G >/dev/null 2>&1 && echo "  caches trimmed" || echo "  trim-caches unavailable"
}

cmd_apps() {
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # Fed by redirect, not a pipe: a checksum mismatch must abort the script, not a subshell.
    while IFS='|' read -r name url want; do
        [ -n "$name" ] || continue
        echo "  fetching $name"
        curl -fsSL -o "$tmp/$name.apk" "$url" || die "download failed: $name"
        got=$(shasum -a 256 "$tmp/$name.apk" | cut -d' ' -f1)
        [ "$got" = "$want" ] || die "checksum mismatch for $name — refusing to install"
        "$ADB" -s "$DEVICE" install -r "$tmp/$name.apk" >/dev/null 2>&1 </dev/null \
            && echo "  installed $name" || echo "  FAILED to install $name"
    done <<EOF
$APKS
EOF
}

cmd_verify() {
    rc=0
    echo "--- DRM services ---"
    for s in drm mediadrm; do
        v=$(sh_ getprop "init.svc.$s" | tr -d '\r')
        if [ "$v" = running ]; then echo "  ok   $s"; else echo "  FAIL $s ($v)"; rc=1; fi
    done
    for k in widevine playready hdcp1; do
        v=$(sh_ getprop "ro.vendor.amzn_drm.$k" | tr -d '\r')
        if [ "$v" = yes ]; then echo "  ok   $k"; else echo "  FAIL $k ($v)"; rc=1; fi
    done

    echo "--- protected packages enabled ---"
    disabled=$(sh_ 'pm list packages -d' | sed 's/^package://' | tr -d '\r')
    bad=0
    for p in $KEEP $MEDIA_APPS; do
        if printf '%s\n' "$disabled" | grep -qx "$p"; then
            echo "  FAIL $p is disabled"; bad=$((bad + 1)); rc=1
        fi
    done
    model=$(sh_ getprop ro.product.device | tr -d '\r')
    if [ "$model" != karat ]; then
        echo "  WARN device is '$model', packages.conf was built for 'karat' — review it first"
    fi
    if [ "$bad" -eq 0 ]; then echo "  ok   none disabled"; fi

    # Drift check: Fire OS re-enables some packages on boot, so "nothing is broken" is not
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
$APKS
EOF

    echo "--- home screen resolves ---"
    # The action is required; category alone returns "No activity found" on Fire OS.
    if sh_ 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME --user 0' \
        | grep -qi 'com.amazon.tv.launcher'; then
        echo "  ok   launcher"
    else
        echo "  FAIL no HOME activity"; rc=1
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

# Fire OS hides the Private DNS menu but Android 11's resolver still honours the setting, which
# makes DNS-over-TLS the only on-device way to block the OTA client that cannot be disabled.
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

# F-Droid ships no LEANBACK_LAUNCHER icon, so it never appears on the Fire TV home screen.
cmd_launch() {
    [ $# -eq 1 ] || die "usage: launch <package>"
    start_pkg "$1" || die "could not start $1"
    echo "started $1"
}

usage() {
    cat <<EOF
usage: $(basename "$0") <command>

  info                 device summary
  backup               snapshot which packages are already disabled
  debloat [tiers...]   disable packages (default: $DEFAULT_TIERS)
                       other tiers: alexa smarthome aggressive
  restore              undo this tool: re-enable its packages and roll settings back
  perf                 animations off, auto-update off, location off, trim caches
  apps                 sideload TV Bro, Obtainium, F-Droid (checksum-pinned)
  verify [--deep]      DRM, protected packages, launcher; --deep also launches media apps
  status               list currently disabled packages
  launch <package>     start an app that has no Fire TV home-screen icon (e.g. F-Droid)
  dns [host|off|show]  system-wide DNS-over-TLS; the only on-device way to block OTA
  sleep <min|never>    display-off and device-sleep timers (both, or 'show')

env: DEVICE (auto-detected when exactly one is attached), ADB, CONF, BACKUP_DIR, SETTINGS_FILE
     EXPECT_SERIAL  refuse to run unless ro.serialno matches (guards against DHCP reassignment)
EOF
}

# Sourcing with FIRETWEAK_LIB=1 loads the functions without dispatching, for test.sh.
if [ -n "${FIRETWEAK_LIB:-}" ]; then return 0; fi

[ $# -ge 1 ] || { usage; exit 2; }
c=$1; shift
case "$c" in
    info|backup|debloat|restore|perf|apps|verify|status|launch|dns|sleep) connect; "cmd_$c" "$@" ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
esac
