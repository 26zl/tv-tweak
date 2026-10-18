#!/bin/sh
# Checks every pin in devices/*/apps.conf against what its project publishes: the digest of a GitHub
# release asset, Kodi's .sha256 file, F-Droid's repo. Fails on a mismatch or a dead URL; a newer
# release is a warning. Needs network access, curl, and gh (CI passes it GITHUB_TOKEN).
set -eu
cd "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

fail=0
bad() { echo "FAIL $*"; fail=1; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$*"; else echo "WARN $*"; fi; }

for conf in devices/*/apps.conf; do
    # A heredoc rather than a pipe, so fail survives the loop.
    while IFS='|' read -r pkg url sum _; do
        case $pkg in ''|'#'*) continue ;; esac
        case $url in
            play) continue ;;
            https://github.com/*/releases/download/*)
                rest=${url#https://github.com/}
                repo=$(echo "$rest" | cut -d/ -f1-2)
                after=${rest#*/releases/download/}
                asset=${after##*/}; tag=${after%/*}
                digest=$(gh api "repos/$repo/releases/tags/$tag" \
                    --jq ".assets[] | select(.name == \"$asset\") | .digest" 2>/dev/null || true)
                if [ "$digest" != "sha256:$sum" ]; then
                    bad "$conf $pkg: GitHub publishes '${digest:-no such asset}' for $tag/$asset"
                fi
                # Tags such as Mullvad's android/2026.12 share a repository with other products:
                # compare with the newest release under the same prefix.
                case $tag in
                    */*) latest=$(gh api "repos/$repo/releases?per_page=50" \
                             --jq "[.[] | select(.prerelease | not) | select(.tag_name | startswith(\"${tag%/*}/\"))][0].tag_name") ;;
                    *)   latest=$(gh api "repos/$repo/releases/latest" --jq .tag_name) ;;
                esac
                if [ -n "$latest" ] && [ "$latest" != "$tag" ]; then
                    warn "$conf $pkg: pinned $tag, latest release is $latest"
                fi ;;
            https://mirrors.kodi.tv/*)
                up=$(curl -fsSL --proto '=https' --max-time 60 "$url.sha256" | cut -d' ' -f1) || up=
                [ "$up" = "$sum" ] || bad "$conf $pkg: Kodi publishes '${up:-nothing}' for $url" ;;
            https://f-droid.org/repo/*)
                if ! curl -fsSI --proto '=https' --max-time 60 "$url" >/dev/null; then
                    if curl -fsSI --proto '=https' --max-time 60 "https://f-droid.org/archive/${url#https://f-droid.org/repo/}" >/dev/null; then
                        warn "$conf $pkg: moved to archive/; apps still finds it, but a newer version is out"
                    else
                        bad "$conf $pkg: neither repo/ nor archive/ has $url"
                    fi
                fi ;;
            *)
                curl -fsSI --proto '=https' --max-time 60 "$url" >/dev/null || bad "$conf $pkg: $url does not answer" ;;
        esac
    done <<EOF
$(grep -v '^[[:space:]]*#' "$conf")
EOF
done

[ "$fail" -eq 0 ] && echo "all pins match" || echo "PIN PROBLEMS"
exit "$fail"
