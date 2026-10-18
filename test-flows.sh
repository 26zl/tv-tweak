#!/bin/sh
# Flow tests: drive tweak.sh end to end against a simulated TV. No device, network or root required.
# A fake adb hands every `adb shell` command line to a shell, joined with spaces exactly as the real
# client does, and fake pm/settings/getprop/cmd/dumpsys keep the TV's state in files.
set -eu
cd "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT=$(pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
t() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; fail=1
    fi
}

# --- the simulated TV ---------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/dev"
cat > "$T/bin/adb" <<'EOF'
#!/bin/sh
# One simulated TV whose state lives in $FAKE_TV; its shell commands live in $FAKE_DEV.
S=$FAKE_TV
if [ "$1" = -s ]; then shift 2; fi
case $1 in
    devices) echo 'List of devices attached'; [ -e "$S/unplugged" ] || printf '127.0.0.1:5555\tdevice\n' ;;
    mdns|disconnect) ;;
    connect) echo "already connected to $2" ;;
    shell)
        shift
        n=$(( $(cat "$S/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/calls"
        if [ -e "$S/unplugged" ] || { [ -e "$S/offline_after" ] && [ "$n" -gt "$(cat "$S/offline_after")" ]; }; then
            echo "error: device '127.0.0.1:5555' not found" >&2; exit 1
        fi
        PATH="$FAKE_DEV:$PATH" exec sh -c "$*" </dev/null ;;
    install)
        shift; while [ "${1#-}" != "$1" ]; do shift; done
        pkg=$(sed -n 's/^pkg://p' "$1")
        [ -n "$pkg" ] || { echo 'Failure [INSTALL_PARSE_FAILED_NOT_APK]'; exit 1; }
        grep -qxF "$pkg" "$S/installed" || echo "$pkg" >> "$S/installed"
        grep -qxF "$pkg" "$S/thirdparty" || echo "$pkg" >> "$S/thirdparty"
        echo Success ;;
    uninstall)
        for f in installed thirdparty; do grep -vxF "$2" "$S/$f" > "$S/$f.tmp" || true; mv "$S/$f.tmp" "$S/$f"; done
        echo Success ;;
    *) echo "fake adb: unsupported: $*" >&2; exit 1 ;;
esac
EOF
cat > "$T/dev/getprop" <<'EOF'
#!/bin/sh
sed -n "s/^$1=//p" "$FAKE_TV/props"
EOF
cat > "$T/dev/pm" <<'EOF'
#!/bin/sh
S=$FAKE_TV
case $1 in
    list)
        shift; shift
        case ${1:-} in
            -d) if [ -e "$S/fail_list_disabled" ]; then
                    echo 'Error: Could not access the Package Manager. Is the system running?' >&2; exit 1
                fi
                sed 's/^/package:/' "$S/disabled" ;;
            -3) sed 's/^/package:/' "$S/thirdparty" ;;
            '') sed 's/^/package:/' "$S/installed" ;;
            *)  grep -F -- "$1" "$S/installed" | sed 's/^/package:/' ;;
        esac ;;
    disable-user|enable)
        verb=$1; shift; if [ "$1" = --user ]; then shift 2; fi; p=$1
        if ! grep -qxF -- "$p" "$S/installed"; then
            echo "Exception occurred while executing '$verb':" >&2
            echo "java.lang.IllegalArgumentException: Unknown package: $p" >&2; exit 255
        fi
        if [ "$verb" = disable-user ] && grep -qxF -- "$p" "$S/protected"; then
            echo "Exception occurred while executing 'disable-user':" >&2
            echo "java.lang.SecurityException: Cannot disable a protected package: $p" >&2; exit 255
        fi
        if [ "$verb" = enable ] && grep -qxF -- "$p" "$S/fail_enable" 2>/dev/null; then
            echo 'Error: simulated failure' >&2; exit 255
        fi
        grep -vxF -- "$p" "$S/disabled" > "$S/disabled.tmp" || true
        mv "$S/disabled.tmp" "$S/disabled"
        if [ "$verb" = disable-user ]; then
            echo "$p" >> "$S/disabled"; echo "Package $p new state: disabled-user"
        else
            echo "Package $p new state: enabled"
        fi ;;
    trim-caches) ;;
    *) echo "pm: unknown command $1" >&2; exit 1 ;;
esac
EOF
cat > "$T/dev/settings" <<'EOF'
#!/bin/sh
S=$FAKE_TV
f=$S/settings/$2/$3
case $1 in
    get) if [ -f "$f" ]; then cat "$f"; else echo null; fi ;;
    put) if grep -qxF -- "$3" "$S/fail_put" 2>/dev/null; then echo 'simulated failure' >&2; exit 1; fi
         mkdir -p "$S/settings/$2"; printf '%s\n' "$4" > "$f" ;;
    delete) rm -f "$f"; echo 'Deleted 1 rows' ;;
    *) exit 1 ;;
esac
EOF
cat > "$T/dev/cmd" <<'EOF'
#!/bin/sh
S=$FAKE_TV
case $2 in
    resolve-activity) echo 'priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false'
                      cat "$S/stock_home" ;;
    query-activities) cat "$S/home_candidates" ;;
    set-home-activity) echo "$3" > "$S/home"; echo Success ;;
    *) exit 1 ;;
esac
EOF
cat > "$T/dev/dumpsys" <<'EOF'
#!/bin/sh
S=$FAKE_TV
case $1 in
    package)
        if [ -s "$S/home" ]; then
            printf '<preferred-activities>\n<item name="%s" match="100000" set="1">\n' "$(cat "$S/home")"
            printf '<cat name="android.intent.category.HOME" />\n</item>\n</preferred-activities>\n'
        else
            echo '<preferred-activities />'
        fi ;;
    connectivity) echo 'UsePrivateDns: false' ;;
esac
EOF
cat > "$T/dev/monkey" <<'EOF'
#!/bin/sh
grep -qxF -- "$2" "$FAKE_TV/installed" && echo 'Events injected: 1'
EOF
cat > "$T/dev/reboot" <<'EOF'
#!/bin/sh
echo reboot >> "$FAKE_TV/reboots"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/dev/am"
printf '#!/bin/sh\necho 4242\n' > "$T/dev/pidof"
chmod +x "$T/bin/adb" "$T/dev"/*

# tv <name> [profile]: a fresh simulated Fire TV Stick 4K Max built from the profile's own lists.
tv() {
    S=$T/tv-$1; P=$ROOT/devices/${2:-firetv-stick-hd}
    rm -rf "$S"; mkdir -p "$S/settings/global" "$S/settings/secure" "$S/settings/system"
    {
        awk '$1 !~ /^#/ && NF >= 2 {print $2}' "$P/packages.conf"
        grep -v '^#' "$P/keep.conf"
        printf 'com.example.userapp\ncom.example.userdisabled\n'
    } | sort -u > "$S/installed"
    awk '$1 == "blocked" {print $2}' "$P/packages.conf" > "$S/protected"
    printf 'com.amazon.dummy.music\ncom.example.userdisabled\n' > "$S/disabled"
    : > "$S/thirdparty"
    cat > "$S/props" <<PROPS
ro.product.model=AFTKRT
ro.product.device=karat
ro.serialno=FAKESERIAL0001
ro.build.version.release=11
ro.build.fingerprint=Amazon/karat/karat:11/PS8180/0000:user/amz-p,release-keys
init.svc.drm=running
init.svc.mediadrm=running
ro.vendor.amzn_drm.widevine=yes
ro.vendor.amzn_drm.playready=yes
ro.vendor.amzn_drm.hdcp1=yes
PROPS
    echo 1.0 > "$S/settings/global/window_animation_scale"
    echo 1.0 > "$S/settings/global/transition_animation_scale"
    echo 3 > "$S/settings/secure/location_mode"
    echo com.amazon.tv.launcher/.ui.HomeActivity_vNext > "$S/stock_home"
    cp "$S/stock_home" "$S/home_candidates"
}
# run <tv> <args...>: tweak.sh against that TV, with its own state directory.
run() {
    s=$1; shift
    FAKE_TV=$T/tv-$s FAKE_DEV=$T/dev ADB=$T/bin/adb DEVICE=127.0.0.1:5555 \
        BACKUP_ROOT=$T/state-$s sh "$ROOT/tweak.sh" "$@"
}
rc() { if run "$@" >/dev/null 2>&1; then echo 0; else echo $?; fi; }
disabled() { sort "$T/tv-$1/disabled" | tr '\n' ' ' | sed 's/ $//'; }
setting() { f=$T/tv-$1/settings/$2/$3; if [ -f "$f" ]; then cat "$f"; else echo null; fi; }
state() { echo "$T/state-$1/firetv-stick-hd"; }

# --- flows -----------------------------------------------------------------------------------------
tv rt; before=$(disabled rt)
t "verify passes on an untouched TV" 0 "$(rc rt verify)"
t "debloat succeeds" 0 "$(rc rt debloat)"
t "tune succeeds" 0 "$(rc rt tune)"
t "verify passes after debloat and tune" 0 "$(rc rt verify)"
t "debloat records only what it changed" "no" \
  "$(grep -qx com.amazon.dummy.music "$(state rt)/applied.txt" && echo yes || echo no)"
run rt tune >/dev/null
t "re-running tune keeps the first original" "1.0" \
  "$(awk '$2 == "window_animation_scale" {print $4}' "$(state rt)/settings.txt")"
t "restore succeeds" 0 "$(rc rt restore)"
t "restore brings back the disabled set" "$before" "$(disabled rt)"
t "restore brings back location_mode" 3 "$(setting rt secure location_mode)"
t "restore unsets what was unset" null "$(setting rt global animator_duration_scale)"
t "verify after a clean restore reports no drift" 0 "$(rc rt verify)"

tv other; run other backup >/dev/null
sed 's/FAKESERIAL0001/FAKESERIAL0002/' "$T/tv-other/props" > "$T/props.tmp" && mv "$T/props.tmp" "$T/tv-other/props"
t "a TV with another serial is refused" 1 "$(rc other debloat)"

tv gone; touch "$T/tv-gone/unplugged"
t "no device is an error" 1 "$(rc gone verify)"

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
