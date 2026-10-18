#!/bin/sh
# Self-test for the parsing logic and the shipped profiles. No device required.
set -eu
cd "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

TWEAK_LIB=1 . ./tweak.sh

fail=0
t() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; fail=1
    fi
}

PROFILE=firetv-stick-4k-max-2023; load_profile

fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'EOF'
# comment with words that look like packages:
#   java.lang.SecurityException: cannot disable
# and com.example.trap should never be emitted
ads	com.example.one		# trailing comment
ads	com.amazon.tv.launcher	# on the keep list, must be filtered
promo	com.example.two
blocked	com.example.blocked
EOF
CONF=$fixture

t "tier returns only its own packages" \
  "com.example.one" \
  "$(tier_pkgs ads 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

t "keep packages are filtered out of every tier" \
  "" \
  "$(tier_pkgs ads 2>/dev/null | grep -x com.amazon.tv.launcher || true)"

t "comment lines never yield packages" \
  "" \
  "$(tier_pkgs ads promo blocked 2>/dev/null | grep -E 'SecurityException|^and$|com.example.trap' || true)"

t "multiple tiers combine" \
  "com.example.one com.example.two" \
  "$(tier_pkgs ads promo 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

t "kept() matches whole lines only" "no" \
  "$(if kept com.amazon.tv.launch; then echo yes; else echo no; fi)"

t "kept() matches a real entry" "yes" \
  "$(if kept com.amazon.tv.launcher; then echo yes; else echo no; fi)"

# Guards the macOS/Linux split between shasum and sha256sum, which `apps` depends on.
KNOWN=3982f19bef1615bccfbb05e321c10e1d4cba3df0e841c2e41eeb6016347653c3
printf 'tweak' > "$fixture.bin"
t "sha256 matches the known digest of 'tweak'" "$KNOWN" "$(sha256 "$fixture.bin")"

# sha256() picks whichever tool exists, so testing it only covers the branch this machine takes.
# Check each implementation directly instead of relying on what a CI runner happens to ship.
if command -v sha256sum >/dev/null 2>&1; then
    t "sha256sum branch" "$KNOWN" "$(sha256sum "$fixture.bin" | cut -d' ' -f1)"
fi
if command -v shasum >/dev/null 2>&1; then
    t "shasum branch" "$KNOWN" "$(shasum -a 256 "$fixture.bin" | cut -d' ' -f1)"
fi
rm -f "$fixture.bin"

t "unknown profile is rejected" "rejected" \
  "$( (PROFILE=no-such-device; load_profile) 2>/dev/null && echo accepted || echo rejected)"

# keep.conf is the safety net, so every spelling of an entry must still protect it, and a profile
# that cannot be read safely must stop the run. Each case edits a scratch copy of the Fire TV profile.
lab=$(mktemp -d)
trap 'rm -rf "$fixture" "$lab"' EXIT
variant() {
    rm -rf "$lab/devices/v"; mkdir -p "$lab/devices"; cp -R devices/firetv-stick-4k-max-2023 "$lab/devices/v"
    keep=$lab/devices/v/keep.conf
}
loads() { if (HERE=$lab; PROFILE=v; CONF=; load_profile) >/dev/null 2>&1; then echo loads; else echo rejected; fi; }
protects() { (HERE=$lab; PROFILE=v; CONF=; load_profile; if kept "$1"; then echo yes; else echo no; fi) 2>/dev/null; }

variant; sed 's/^com\.amazon\.firebat$/com.amazon.firebat   # Prime Video/' "$keep" > "$keep.new"; mv "$keep.new" "$keep"
t "keep.conf: a comment after an entry still protects it" "yes" "$(protects com.amazon.firebat)"
variant; sed 's/$/\r/' "$keep" > "$keep.new"; mv "$keep.new" "$keep"
t "keep.conf: CRLF line endings still protect" "yes" "$(protects com.amazon.firebat)"
variant; sed 's/^com\.amazon\.firebat$/  com.amazon.firebat  /' "$keep" > "$keep.new"; mv "$keep.new" "$keep"
t "keep.conf: surrounding spaces still protect" "yes" "$(protects com.amazon.firebat)"
variant
t "media_apps are protected even when keep.conf omits them" "yes" "$(protects com.netflix.ninja)"
variant; rm "$keep"
t "a missing keep.conf stops the run" "rejected" "$(loads)"
variant; grep '^#' "$keep" > "$keep.new"; mv "$keep.new" "$keep"
t "a keep.conf with no entries stops the run" "rejected" "$(loads)"
variant; printf 'ads\tcom.amazon.firebat;\n' >> "$lab/devices/v/packages.conf"
t "packages.conf: shell syntax after a name stops the run" "rejected" "$(loads)"
variant; printf 'model="%s(touch %s/ran)"\n' '$' "$lab" >> "$lab/devices/v/device.conf"
t "device.conf is read as data, never run" "rejected none" "$(loads) $(ls "$lab/ran" 2>/dev/null || echo none)"
variant; printf 'com.example.app|http://example.com/a.apk|%064d\n' 0 >> "$lab/devices/v/apps.conf"
t "apps.conf: a plain-http url stops the run" "rejected" "$(loads)"
variant; printf 'com.example.app|https://example.com/a.apk|\n' >> "$lab/devices/v/apps.conf"
t "apps.conf: a missing checksum stops the run" "rejected" "$(loads)"
variant; printf 'global\tfoo\tbar;reboot\n' >> "$lab/devices/v/settings.conf"
t "settings.conf: shell syntax in a value stops the run" "rejected" "$(loads)"

# Every shipped profile must parse, name a launcher, and not list anything its own keep list
# would refuse anyway.
for d in devices/*/; do
    p=$(basename "$d")
    CONF=; MEDIA_APPS=
    PROFILE=$p; load_profile
    t "$p: device.conf names a model and launcher" "yes" \
      "$(if [ -n "$model" ] && [ -n "$launcher" ]; then echo yes; else echo no; fi)"
    t "$p: default tiers exist in packages.conf" "" \
      "$(for tier in $tiers; do awk -v t="$tier" '$1==t' "$CONF" | grep -q . || echo "$tier"; done)"
    # Read independently of kept(), so a parsing bug there cannot hide an overlap here.
    overlap=$(conf_lines "$CONF" | awk '{print $2}' | LC_ALL=C sort -u > "$lab/pkgs"
              # shellcheck disable=SC2086  # media_apps is a space-separated list of package names
              { conf_lines "$d/keep.conf"; printf '%s\n' $media_apps; } | LC_ALL=C sort -u > "$lab/keep"
              LC_ALL=C comm -12 "$lab/pkgs" "$lab/keep")
    t "$p: packages.conf does not fight keep.conf or media_apps" "" "$overlap"
    t "$p: apps.conf entries are <pkg>|<url>|<sha256> or <pkg>|play|, then optionally |optional" "" \
      "$(printf '%s\n' "$APPS" | grep -v '^$' | grep -vE '^[a-z0-9_.]+\|(https://[^|]+\|[0-9a-f]{64}|play\|)(\|optional)?$' || true)"
    t "$p: settings.conf lines are <ns> <key> <value> [tier]" "" \
      "$(printf '%s\n' "$SETTINGS" | grep -v '^[[:space:]]*$' | awk 'NF != 3 && NF != 4 {print}')"
    t "$p: a tier named in settings.conf exists in packages.conf" "" \
      "$(printf '%s\n' "$SETTINGS" | awk 'NF == 4 {print $4}' | sort -u | while read -r tier; do
            conf_lines "$CONF" | awk -v t="$tier" '$1 == t {f = 1} END {exit !f}' || echo "$tier"; done)"
done

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
