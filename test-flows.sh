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
        if [ -s "$S/hang_on" ]; then case "$*" in *"$(cat "$S/hang_on")"*) exec sleep 10 ;; esac; fi
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
         mkdir -p "$S/settings/$2"; printf '%s\n' "$4" > "$f"
         if grep -qxF -- "$3" "$S/put_then_drop" 2>/dev/null; then echo 'error: closed' >&2; exit 1; fi ;;
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
    S=$T/tv-$1; P=$ROOT/devices/${2:-firetv-stick-4k-max-2023}
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
        TWEAK_STATE=$T/state-$s sh "${TWEAK_SH:-$ROOT/tweak.sh}" "$@"
}
# copy <name>: a scratch checkout to edit profiles in; use it with TWEAK_SH=$T/<name>/tweak.sh.
copy() { rm -rf "${T:?}/$1"; mkdir "$T/$1"; cp "$ROOT/tweak.sh" "$T/$1/"; cp -R "$ROOT/devices" "$T/$1/"; }
rc() { if run "$@" >/dev/null 2>&1; then echo 0; else echo $?; fi; }
disabled() { sort "$T/tv-$1/disabled" | tr '\n' ' ' | sed 's/ $//'; }
setting() { f=$T/tv-$1/settings/$2/$3; if [ -f "$f" ]; then cat "$f"; else echo null; fi; }
state() { echo "$T/state-$1/firetv-stick-4k-max-2023/FAKESERIAL${2:-0001}"; }

# --- flows -----------------------------------------------------------------------------------------
tv rt; before=$(disabled rt)
t "verify passes on an untouched TV" 0 "$(rc rt verify)"
t "debloat succeeds" 0 "$(rc rt debloat)"
t "tune succeeds" 0 "$(rc rt tune)"
t "verify passes after debloat and tune" 0 "$(rc rt verify)"
t "debloat records only what it changed" "no" \
  "$(grep -qx com.amazon.dummy.music "$(state rt)/applied.txt" && echo yes || echo no)"
run rt tune >/dev/null
t "re-running tune keeps the first original" "'1.0'" \
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

# Asking for help, or making a typo, never reaches the TV.
tv args
for c in dns tune restore apps debloat; do
    t "'$c --help' prints usage and exits 0" 0 "$(rc args "$c" --help)"
done
t "... and changed nothing on the TV" "null 1.0" \
  "$(setting args global private_dns_specifier) $(setting args global window_animation_scale)"
t "--version needs no device" "tweak 0.1.0" "$(run gone --version)"
t "an unknown command exits 2" 2 "$(rc args resotre)"
t "... and says so on stderr only" "error: unknown command 'resotre'|" \
  "$(run args resotre 2>&1 >/dev/null | head -1)|$(run args resotre 2>/dev/null)"
t "no command exits 2" 2 "$(rc args)"
t "--device after the command is honoured" 1 "$(rc args verify --device no-such-profile)"
t "a profile name is a name, not a path" 2 "$(rc args --device ../../tmp verify)"
t "an unknown tier is refused" 1 "$(rc args debloat alexaa)"
t "... before anything is disabled" "$(disabled gone)" "$(disabled args)"
t "dns refuses shell syntax" 2 "$(rc args dns 'dns.example;reboot')"
t "... and the TV never ran it" none "$(cat "$T/tv-args/reboots" 2>/dev/null || echo none)"
t "dns refuses an IP address" 2 "$(rc args dns 1.1.1.1)"
t "dns refuses a name without a dot" 2 "$(rc args dns example)"
t "dns sets a hostname" "0 dns.example.com hostname" \
  "$(rc args dns dns.example.com) $(setting args global private_dns_specifier) $(setting args global private_dns_mode)"
t "dns auto restores Android's default mode" "0 opportunistic" \
  "$(rc args dns auto) $(setting args global private_dns_mode)"
t "launch refuses shell syntax" 2 "$(rc args launch 'x;reboot')"
t "sleep refuses 0" 2 "$(rc args sleep 0)"
t "sleep refuses more than fits in 32-bit milliseconds" 2 "$(rc args sleep 35792)"
t "sleep takes minutes" "0 1800000" "$(rc args sleep 30) $(setting args system screen_off_timeout)"

# restore keeps what it could not undo, and says so.
tv pf; run pf debloat >/dev/null 2>&1; run pf tune >/dev/null 2>&1
echo com.amazon.tv.acr > "$T/tv-pf/fail_enable"; echo location_mode > "$T/tv-pf/fail_put"
t "restore exits 1 when an entry fails" 1 "$(rc pf restore)"
t "... keeps the package it could not re-enable" "com.amazon.tv.acr" "$(cat "$(state pf)/applied.txt")"
t "... keeps the setting it could not restore" "secure location_mode 0 '3'" "$(cat "$(state pf)/settings.txt")"
t "... and verify still accounts for it" "yes" \
  "$(run pf verify 2>/dev/null | grep -q 'all 1 still disabled' && echo yes || echo no)"
rm "$T/tv-pf/fail_enable" "$T/tv-pf/fail_put"
t "a second restore finishes the job" "0 3" "$(rc pf restore) $(setting pf secure location_mode)"
t "... and leaves nothing recorded" "none" "$(ls "$(state pf)/applied.txt" "$(state pf)/settings.txt" 2>/dev/null || echo none)"

tv drop; run drop debloat >/dev/null 2>&1; run drop tune >/dev/null 2>&1
echo $(( $(cat "$T/tv-drop/calls") + 12 )) > "$T/tv-drop/offline_after"
t "a TV that drops off mid-restore stops it with exit 1" 1 "$(rc drop restore)"
t "... and the rest stays recorded" "yes yes" \
  "$([ -s "$(state drop)/applied.txt" ] && echo yes) $([ -s "$(state drop)/settings.txt" ] && echo yes)"
rm "$T/tv-drop/offline_after"
t "... so restore can finish later" "0 $(disabled rt)" "$(rc drop restore) $(disabled drop)"

tv so; run so tune >/dev/null 2>&1; run so dns dns.example.com >/dev/null 2>&1; run so sleep never >/dev/null 2>&1
t "restore rolls settings back when no package was recorded" 0 "$(rc so restore)"
t "... location, DNS and timers" "3 null null" \
  "$(setting so secure location_mode) $(setting so global private_dns_mode) $(setting so system screen_off_timeout)"
tv allon; awk '$1 ~ /^(ads|promo|ota|cruft)$/ {print $2}' "$ROOT/devices/firetv-stick-4k-max-2023/packages.conf" >> "$T/tv-allon/disabled"
run allon debloat >/dev/null 2>&1; run allon tune >/dev/null 2>&1
t "restore works after a debloat that found everything already off" "0 3" \
  "$(rc allon restore) $(setting allon secure location_mode)"

# A read that fails is an error, never an empty answer.
tv rd; echo com.amazon.firebat >> "$T/tv-rd/disabled"; touch "$T/tv-rd/fail_list_disabled"
t "verify fails when the disabled list cannot be read" 1 "$(rc rd verify)"
t "backup refuses to record an unreadable list" "1 none" "$(rc rd backup) $(ls "$(state rd)"/snapshot-* 2>/dev/null || echo none)"

# Failures carry their reason and the exit code.
tv bl
t "debloat exits 1 when packages fail" 1 "$(rc bl debloat blocked)"
t "... and says why" "protected by the system" \
  "$(run bl debloat blocked 2>&1 >/dev/null | sed -n 's/.*FAILED *[^:]*: //p' | sort -u)"

# Originals are recorded before the write, and survive spaces.
tv ahead; echo location_mode > "$T/tv-ahead/put_then_drop"
run ahead tune >/dev/null 2>&1 || true
rm "$T/tv-ahead/put_then_drop"; run ahead tune >/dev/null 2>&1
t "a write that lands as the connection drops keeps the real original" "'3'" \
  "$(awk '$2 == "location_mode" {print $4}' "$(state ahead)/settings.txt")"
copy sp; printf 'global\tdevice_name\tTV\n' >> "$T/sp/devices/firetv-stick-4k-max-2023/settings.conf"
tv sp; echo "Living Room TV" > "$T/tv-sp/settings/global/device_name"
TWEAK_SH=$T/sp/tweak.sh run sp tune >/dev/null 2>&1; TWEAK_SH=$T/sp/tweak.sh run sp tune >/dev/null 2>&1
TWEAK_SH=$T/sp/tweak.sh run sp restore >/dev/null 2>&1
t "an original with spaces comes back whole" "Living Room TV" "$(setting sp global device_name)"
tv ml; printf 'two\nlines\n' > "$T/tv-ml/settings/global/window_animation_scale"
t "a value that spans lines is left alone" "1 two" \
  "$(rc ml tune) $(head -1 "$T/tv-ml/settings/global/window_animation_scale")"

# A TV that stops answering does not hang the run.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || command -v perl >/dev/null 2>&1; then
    tv hang; echo 'disable-user --user 0 com.amazon.tv.acr' > "$T/tv-hang/hang_on"
    t "a command that never answers times out" "1 no answer within 2s" \
      "$(TWEAK_TIMEOUT=2 rc hang debloat ads) $(TWEAK_TIMEOUT=2 run hang debloat ads 2>&1 >/dev/null | sed -n 's/.*acr: //p')"
fi

# The undo record lives outside the clone, one per TV.
copy home; mkdir -p "$T/home"; tv home
case $(uname -s) in
    Darwin) where="$T/home/Library/Application Support/tv-tweak" ;;
    *) where="$T/home/.local/state/tv-tweak" ;;
esac
FAKE_TV=$T/tv-home FAKE_DEV=$T/dev ADB=$T/bin/adb DEVICE=127.0.0.1:5555 HOME=$T/home XDG_STATE_HOME='' \
    sh "$T/home/tweak.sh" debloat >/dev/null 2>&1
t "state lives outside the clone by default" "yes no" \
  "$([ -s "$where/firetv-stick-4k-max-2023/FAKESERIAL0001/applied.txt" ] && echo yes || echo no) $([ -e "$T/home/backups" ] && echo yes || echo no)"

tv base; run base backup >/dev/null; b=$(cat "$(state base)/baseline.txt")
run base debloat >/dev/null 2>&1; run base backup >/dev/null
t "the baseline survives a backup taken after debloat" "$b" "$(cat "$(state base)/baseline.txt")"
t "every run that changes something is logged" "yes" \
  "$(grep -q 'debloat: exit 0' "$(state base)/log.txt" && grep -q 'backup — tweak' "$(state base)/log.txt" && echo yes || echo no)"

# State written by an older version, in backups/<profile>/ inside the clone, moves to its TV's place.
copy legacy; L=$T/legacy/backups/firetv-stick-hd; mkdir -p "$L"
echo FAKESERIAL0001 > "$L/serial.txt"
printf '# disabled at backup time\ncom.amazon.dummy.music\ncom.example.userdisabled\n' > "$L/state-20260801-120000.txt"
printf '# disabled at backup time\ncom.amazon.tv.acr\n' > "$L/state-20260901-120000.txt"
ln -s state-20260901-120000.txt "$L/latest.txt"
printf 'com.amazon.tv.acr\ncom.amazon.aca\n' > "$L/applied.txt"
printf 'secure location_mode 0 3\nglobal window_animation_scale 0.0 1.0\n' > "$L/settings.txt"
tv legacy; printf 'com.amazon.tv.acr\ncom.amazon.aca\n' >> "$T/tv-legacy/disabled"
echo 0 > "$T/tv-legacy/settings/secure/location_mode"; echo 0.0 > "$T/tv-legacy/settings/global/window_animation_scale"
TWEAK_SH=$T/legacy/tweak.sh run legacy verify >/dev/null 2>&1 || true
t "older state moves out of the clone" "gone" "$([ -e "$T/legacy/backups" ] && echo still-there || echo gone)"
t "... keeping the restore list and settings" "yes yes" \
  "$([ -s "$(state legacy)/applied.txt" ] && echo yes) $([ -s "$(state legacy)/settings.txt" ] && echo yes)"
t "... with the oldest snapshot as the baseline" "com.amazon.dummy.music com.example.userdisabled" \
  "$(grep -v '^#' "$(state legacy)/baseline.txt" | tr '\n' ' ' | sed 's/ $//')"
t "... and restore undoes it" "0 3 1.0" \
  "$(TWEAK_SH=$T/legacy/tweak.sh rc legacy restore) $(setting legacy secure location_mode) $(setting legacy global window_animation_scale)"
copy legacy2; mkdir -p "$T/legacy2/backups/firetv-stick-hd"; echo OTHERSERIAL > "$T/legacy2/backups/firetv-stick-hd/serial.txt"
tv legacy2; TWEAK_SH=$T/legacy2/tweak.sh run legacy2 verify >/dev/null 2>&1 || true
t "older state from another TV stays where it is" "yes" "$([ -e "$T/legacy2/backups/firetv-stick-hd/serial.txt" ] && echo yes)"

# A second TV of the same model gets its own record, and only when asked.
tv a; tv b; sed 's/FAKESERIAL0001/FAKESERIAL0002/' "$T/tv-b/props" > "$T/props.tmp" && mv "$T/props.tmp" "$T/tv-b/props"
echo com.amazon.tahoe >> "$T/tv-b/disabled"; echo 1 > "$T/tv-b/settings/secure/location_mode"
both() { s=$1; shift; FAKE_TV=$T/tv-$s FAKE_DEV=$T/dev ADB=$T/bin/adb DEVICE=127.0.0.1:5555 TWEAK_STATE=$T/state-ab sh "$ROOT/tweak.sh" "$@"; }
both a debloat >/dev/null 2>&1; both a tune >/dev/null 2>&1
t "a second TV of the same model is refused" 1 "$(if both b debloat >/dev/null 2>&1; then echo 0; else echo $?; fi)"
both b debloat --new-device >/dev/null 2>&1; both b tune >/dev/null 2>&1; both b restore >/dev/null 2>&1
t "... and with --new-device keeps its own record" "disabled 1" \
  "$(grep -qx com.amazon.tahoe "$T/tv-b/disabled" && echo disabled || echo enabled) $(setting b secure location_mode)"
t "... while the first TV can still be restored" "0 3" \
  "$(if both a restore >/dev/null 2>&1; then echo 0; else echo $?; fi) $(setting a secure location_mode)"

# A profile changes only the device it was built for, under its current name.
tv alias
t "the old profile name still works" "0" "$(rc alias --device firetv-stick-hd verify)"
t "... and says what it is now" "yes" \
  "$(run alias --device firetv-stick-hd verify 2>&1 >/dev/null | grep -q 'now firetv-stick-4k-max-2023' && echo yes || echo no)"
tv model; before=$(disabled model)
t "another device's profile is refused for changes" 1 "$(rc model --device sharp-4k-googletv debloat)"
t "... before anything is disabled" "$before" "$(disabled model)"
t "... unless --force says it was checked" 0 "$(rc model --device sharp-4k-googletv --force tune)"
tv fw; sed 's/^ro.build.version.release=11$/ro.build.version.release=12/' "$T/tv-fw/props" > "$T/props.tmp" && mv "$T/props.tmp" "$T/tv-fw/props"
t "another Android release is a warning, not a stop" "0 yes" \
  "$(rc fw tune) $(run fw tune 2>&1 >/dev/null | grep -q 'WARN this TV runs Android 12' && echo yes || echo no)"
tv ota; run ota backup >/dev/null
sed 's/PS8180/PS8190/' "$T/tv-ota/props" > "$T/props.tmp" && mv "$T/props.tmp" "$T/tv-ota/props"
t "verify notices a firmware update since the first backup" "yes" \
  "$(run ota verify 2>/dev/null | grep -q 'WARN the firmware changed' && echo yes || echo no)"

# keep.conf protects whatever the spelling, and a profile that cannot be read safely stops the run.
copy kc; P=$T/kc/devices/firetv-stick-4k-max-2023
printf 'ads\tcom.amazon.firebat\t# a bad edit\n' >> "$P/packages.conf"
sed 's/^com\.amazon\.firebat$/com.amazon.firebat   # Prime Video/' "$P/keep.conf" > "$P/keep.new"; mv "$P/keep.new" "$P/keep.conf"
tv kc; TWEAK_SH=$T/kc/tweak.sh run kc debloat ads >/dev/null 2>&1 || true
t "a listed keep.conf entry stays enabled whatever packages.conf says" "enabled" \
  "$(grep -qx com.amazon.firebat "$T/tv-kc/disabled" && echo disabled || echo enabled)"
copy semi; printf 'ads\tcom.amazon.firebat;\n' >> "$T/semi/devices/firetv-stick-4k-max-2023/packages.conf"
tv semi; before=$(disabled semi)
t "a ';' after a package name stops debloat" 1 "$(TWEAK_SH=$T/semi/tweak.sh rc semi debloat ads)"
t "... before anything is disabled" "$before" "$(disabled semi)"

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
