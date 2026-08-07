#!/usr/bin/env bash
# Regenerate patches/sqlite3.go.patch from the current state of sqlite3.go vs
# the upstream mattn version pinned in VERSION.
#
# Run this after editing sqlite3.go so the patch tracks your changes.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/sqlite3"
PATCH="$ROOT/patches/sqlite3.go.patch"
VERSION_FILE="$ROOT/VERSION"

die() { echo "[regen-patch] error: $*" >&2; exit 1; }

[ -f "$VERSION_FILE" ] || die "missing $VERSION_FILE — run scripts/update.sh first"
MATTN_VER="$(awk -F= '$1=="mattn"{print $2; exit}' "$VERSION_FILE")"
[ -n "$MATTN_VER" ] || die "no mattn= field in $VERSION_FILE"

MATTN_REPO_DEFAULT="https://github.com/alvarolm/go-sqlite3.git"
MATTN_REPO="${1:-$MATTN_REPO_DEFAULT}"

WORKDIR="$(mktemp -d -t regen-patch.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

case "$MATTN_REPO" in
    http://*|https://*|git@*)
        git -c advice.detachedHead=false clone --quiet --depth 1 \
            --branch "$MATTN_VER" "$MATTN_REPO" "$WORKDIR/repo"
        UPSTREAM="$WORKDIR/repo/sqlite3.go"
        ;;
    *)
        [ -d "$MATTN_REPO/.git" ] || die "not a git repo: $MATTN_REPO"
        git -C "$MATTN_REPO" archive "$MATTN_VER" sqlite3.go | tar -x -C "$WORKDIR"
        UPSTREAM="$WORKDIR/sqlite3.go"
        ;;
esac

[ -f "$UPSTREAM" ] || die "could not stage upstream sqlite3.go"

mkdir -p "$(dirname "$PATCH")"
diff -u --label a/sqlite3.go --label b/sqlite3.go \
    "$UPSTREAM" "$TARGET/sqlite3.go" > "$PATCH" || true

if [ ! -s "$PATCH" ]; then
    echo "[regen-patch] no diff vs mattn $MATTN_VER — patch is now empty" >&2
else
    echo "[regen-patch] wrote $(wc -l < "$PATCH") lines to $PATCH" >&2
fi
