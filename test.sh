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

PROFILE=firetv-stick-hd; load_profile

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

# Every shipped profile must parse, name a launcher, and not list anything its own keep list
# would refuse anyway.
for d in devices/*/; do
    p=$(basename "$d")
    CONF=
    PROFILE=$p; load_profile
    t "$p: device.conf names a model and launcher" "yes" \
      "$(if [ -n "$model" ] && [ -n "$launcher" ]; then echo yes; else echo no; fi)"
    t "$p: default tiers exist in packages.conf" "" \
      "$(for tier in $tiers; do awk -v t="$tier" '$1==t' "$CONF" | grep -q . || echo "$tier"; done)"
    # shellcheck disable=SC2013  # package names never contain whitespace
    overlap=$(for pkg in $(awk '$1 !~ /^#/ && $2 ~ /^[a-z]/ {print $2}' "$CONF" | sort -u); do
        if kept "$pkg"; then echo "$pkg"; fi
    done)
    t "$p: packages.conf does not fight keep.conf" "" "$overlap"
    t "$p: apps.conf entries are <pkg>|<url>|<sha256> or <pkg>|play|" "" \
      "$(printf '%s\n' "$APPS" | grep -v '^$' | grep -vE '^[a-z0-9_.]+\|(https://[^|]+\|[0-9a-f]{64}|play\|)$' || true)"
    t "$p: settings.conf lines are <ns> <key> <value>" "" \
      "$(printf '%s\n' "$SETTINGS" | grep -v '^[[:space:]]*$' | awk 'NF != 3 {print}')"
done

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
