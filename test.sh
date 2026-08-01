#!/bin/sh
# Self-test for the parsing logic. No device required.
set -eu
cd "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

FIRETWEAK_LIB=1 . ./firetweak.sh

fail=0
t() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"; echo "       expected: [$2]"; echo "       actual:   [$3]"; fail=1
    fi
}

fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'EOF'
# comment with words that look like packages:
#   java.lang.SecurityException: cannot disable
# and com.example.trap should never be emitted
ads	com.example.one		# trailing comment
ads	com.amazon.tv.launcher	# on the KEEP list, must be filtered
promo	com.example.two
blocked	com.example.blocked
EOF
CONF=$fixture

t "tier returns only its own packages" \
  "com.example.one" \
  "$(tier_pkgs ads 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

t "KEEP packages are filtered out of every tier" \
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
printf 'firetweak' > "$fixture.bin"
t "sha256 matches the known digest of 'firetweak'" \
  "1493155f2dd52183bd8c82689436f3099d231b10b001c0bc4387497e35b8cf73" \
  "$(sha256 "$fixture.bin")"
rm -f "$fixture.bin"

# The shipped config must not name anything the KEEP guard would refuse anyway.
# shellcheck disable=SC2013  # package names never contain whitespace
overlap=$(for p in $(awk '$1 !~ /^#/ && $2 ~ /^[a-z]/ {print $2}' packages.conf | sort -u); do
    if kept "$p"; then echo "$p"; fi
done)
t "packages.conf does not fight the KEEP list" "" "$overlap"

[ "$fail" -eq 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
