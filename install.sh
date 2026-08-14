#!/usr/bin/env bash
# Build a ReleaseFast holocTTY and install it on this machine.
#
# Default prefix is ~/.local (no root). The desktop file, icons, terminfo,
# and shell integration all land on the XDG paths under that prefix.
#
#   ./install.sh
#   ./install.sh --prefix "$HOME/.local"
#   ./install.sh --system
#   ./install.sh -- -Dgtk-x11=false

set -o nounset -o pipefail -o errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

PREFIX="${PREFIX:-${HOME}/.local}"
SYSTEM=0
DRY_RUN=0
JOBS=""
ZIG="${ZIG:-zig}"
EXTRA=()

usage() {
    cat <<EOF
Usage: $0 [options] [-- zig-build-args...]

Build holocTTY with -Doptimize=ReleaseFast and install it.

Options:
  -p, --prefix DIR   Install prefix (default: \$HOME/.local, or PREFIX)
      --system       Install to /usr (stages as you, copies with sudo)
  -j, --jobs N       Limit Zig compile jobs
      --dry-run      Print commands without running them
  -h, --help         Show this help

Environment:
  PREFIX             Same as --prefix
  ZIG                Zig binary (default: zig)

Anything after -- is passed through to zig build.
EOF
}

log() { printf '==> %s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; }

run() {
    if ((DRY_RUN)); then
        printf 'dry-run:'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

while (($#)); do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        -p | --prefix)
            [[ $# -ge 2 ]] || { err "--prefix needs a directory"; exit 2; }
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            shift
            ;;
        --system)
            SYSTEM=1
            PREFIX=/usr
            shift
            ;;
        -j | --jobs)
            [[ $# -ge 2 ]] || { err "--jobs needs a number"; exit 2; }
            JOBS="$2"
            shift 2
            ;;
        --jobs=*)
            JOBS="${1#--jobs=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --)
            shift
            EXTRA+=("$@")
            break
            ;;
        -*)
            err "unknown option: $1"
            usage >&2
            exit 2
            ;;
        *)
            err "unexpected argument: $1"
            usage >&2
            exit 2
            ;;
    esac
done

if ! command -v "$ZIG" >/dev/null 2>&1; then
    err "zig not found (looked for '${ZIG}'). Install Zig or set ZIG=."
    exit 1
fi

PREFIX="$(readlink -f "$PREFIX" 2>/dev/null || realpath "$PREFIX" 2>/dev/null || echo "$PREFIX")"

need_root=0
if ((SYSTEM)); then
    need_root=1
elif [[ -e "$PREFIX" && ! -w "$PREFIX" ]]; then
    need_root=1
elif [[ ! -e "$PREFIX" ]]; then
    parent="$PREFIX"
    while [[ ! -e "$parent" && "$parent" != / ]]; do
        parent="$(dirname "$parent")"
    done
    if [[ ! -w "$parent" ]]; then
        need_root=1
    fi
fi

zig_args=(
    build
    -Doptimize=ReleaseFast
    --prefix "$PREFIX"
)
if [[ -n "$JOBS" ]]; then
    zig_args+=(-j"$JOBS")
fi
if ((${#EXTRA[@]})); then
    zig_args+=("${EXTRA[@]}")
fi

log "zig $($ZIG version) → ${PREFIX}/bin/holoctty (ReleaseFast)"

if ((need_root)); then
    STAGE="${TMPDIR:-/tmp}/holoctty-install.$$"
    if ! ((DRY_RUN)); then
        mkdir -p "$STAGE"
        trap 'rm -rf "$STAGE"' EXIT
    fi
    log "staging into ${STAGE} (prefix ${PREFIX} is not writable)"
    run env DESTDIR="$STAGE" "$ZIG" "${zig_args[@]}"
    staged="${STAGE}${PREFIX}"
    if ((DRY_RUN)); then
        log "would sudo-copy ${staged}/. → ${PREFIX}/"
    else
        [[ -d "$staged" ]] || { err "staged install missing at ${staged}"; exit 1; }
        log "copying into ${PREFIX} with sudo"
        run sudo mkdir -p "$PREFIX"
        run sudo cp -a "${staged}/." "$PREFIX/"
    fi
    share="${PREFIX}/share"
    refresh=(sudo)
else
    run "$ZIG" "${zig_args[@]}"
    share="${PREFIX}/share"
    refresh=()
fi

refresh_cmd() {
    local bin="$1"
    shift
    if command -v "$bin" >/dev/null 2>&1; then
        run "${refresh[@]}" "$bin" "$@" || true
    fi
}

if [[ -d "${share}/applications" ]]; then
    refresh_cmd update-desktop-database "${share}/applications"
    refresh_cmd kbuildsycoca6 --noincremental
    if ! command -v kbuildsycoca6 >/dev/null 2>&1; then
        refresh_cmd kbuildsycoca5 --noincremental
    fi
fi
if [[ -d "${share}/icons/hicolor" ]]; then
    refresh_cmd gtk-update-icon-cache -f -t "${share}/icons/hicolor"
fi

bin="${PREFIX}/bin/holoctty"
if ! ((DRY_RUN)); then
    [[ -x "$bin" ]] || { err "install finished but ${bin} is missing"; exit 1; }
    log "installed ${bin}"
    "$bin" --version
fi

if [[ "$PREFIX/bin" == "${HOME}/.local/bin" ]]; then
    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*) ;;
        *)
            log "note: ${HOME}/.local/bin is not on PATH; add it so 'holoctty' works from a shell"
            ;;
    esac
fi

log "done"
