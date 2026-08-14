#!/bin/sh
# Rebase this fork onto ghostty-org/ghostty.
# Never pushes. Never opens a PR. Never touches origin unless you do.
set -eu

cd "$(dirname "$0")/.."

if ! git remote get-url upstream >/dev/null 2>&1; then
    echo "missing remote 'upstream' (expected github.com:ghostty-org/ghostty)" >&2
    exit 1
fi

upstream_url=$(git remote get-url upstream)
case "$upstream_url" in
    *ghostty-org/ghostty*) ;;
    *)
        echo "upstream remote is not ghostty-org/ghostty: $upstream_url" >&2
        exit 1
        ;;
esac

rebase=0
if [ "${1:-}" = "--rebase" ]; then
    rebase=1
elif [ -n "${1:-}" ]; then
    echo "usage: $0 [--rebase]" >&2
    exit 1
fi

if [ "$rebase" -eq 1 ]; then
    git fetch upstream
fi

if ! git rev-parse --verify upstream/main >/dev/null 2>&1; then
    echo "no upstream/main ref; run: git fetch upstream" >&2
    exit 1
fi

mb=$(git merge-base HEAD upstream/main)
behind=$(git rev-list --count HEAD..upstream/main)
ahead=$(git rev-list --count upstream/main..HEAD)

echo "HEAD     $(git rev-parse --short HEAD)"
echo "upstream $(git rev-parse --short upstream/main)  ($upstream_url)"
echo "base     $(git rev-parse --short "$mb")"
echo "ahead    $ahead   behind $behind"

if [ "$rebase" -eq 0 ]; then
    echo
    echo "dry run. pass --rebase to fetch and rebase onto upstream/main."
    exit 0
fi

if [ "$behind" -eq 0 ]; then
    echo "already up to date with upstream/main"
    exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is dirty; commit or stash first" >&2
    exit 1
fi

git rebase upstream/main

echo
echo "rebased. suggested checks:"
echo "  zig build -Demit-macos-app=false"
echo "  zig build test -Dtest-filter='gtk tabs location'"
echo "  zig build test -Dtest-filter='gtk session'"
echo "  zig build test -Dtest-filter='window-padding-color parses extend-full'"
