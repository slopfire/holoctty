#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="$workspace/.zig-cache"
limit_gib="${BUILD_CACHE_LIMIT_GIB:-32}"
limit_kib=$((limit_gib * 1024 * 1024))

[[ -d "$cache" ]] || exit 0

git_dir="$(git -C "$workspace" rev-parse --absolute-git-dir)"
exec 9>"$git_dir/cache-prune.lock"
flock -n 9 || exit 0

size_kib="$(du -sk -- "$cache" | cut -f1)"
((size_kib > limit_kib)) || exit 0

for proc_dir in /proc/[0-9]*; do
  [[ -r "$proc_dir/comm" ]] || continue
  read -r command <"$proc_dir/comm" || continue
  case "$command" in
    zig|ziglang)
      process_cwd="$(readlink "$proc_dir/cwd" 2>/dev/null || true)"
      case "$process_cwd/" in
        "$workspace/"*)
          printf 'Build cache is %s GiB, but Zig is active in this repository. Skipping cleanup.\n' "$((size_kib / 1024 / 1024))" >&2
          exit 0
          ;;
      esac
      ;;
  esac
done

printf 'Build cache is %s GiB. Removing %s before the next build.\n' \
  "$((size_kib / 1024 / 1024))" "$cache"
rm -rf -- "$cache"
