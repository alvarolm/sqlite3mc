#!/usr/bin/env bash
# Rebuild this package — a hybrid of mattn/go-sqlite3 + SQLite3MultipleCiphers.
#
# Re-pulls both upstreams at chosen versions, copies/renames the right files
# into the repo root, applies the local sqlite3.go patch, and stamps VERSION.
#
# Usage:
#   scripts/update.sh [flags]
#
# Flags:
#   --mattn TAG       go-sqlite3 git tag/branch   (default: from VERSION)
#   --mattn-base TAG  mattn tag the fork ref is based on, recorded in VERSION
#                                                 (default: from VERSION)
#   --mc TAG          SQLite3MultipleCiphers tag  (default: from VERSION)
#   --version VER     local hybrid version stamp  (default: keep current; "0.1.0" if absent)
#   --mattn-repo SRC  local git path or URL       (default: https://github.com/alvarolm/go-sqlite3.git)
#   --mc-repo SRC     local git path or URL       (default: https://github.com/utelle/SQLite3MultipleCiphers.git)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/sqlite3"
PATCH="$ROOT/patches/sqlite3.go.patch"
VERSION_FILE="$ROOT/VERSION"
GO_MODULE_PATH="github.com/alvarolm/sqlite3mc/sqlite3"

die() { echo "[update] error: $*" >&2; exit 1; }
log() { echo "[update] $*" >&2; }

read_version_field() {
    local key="$1"
    [ -f "$VERSION_FILE" ] || return 0
    awk -F= -v k="$key" '$1==k {print $2; exit}' "$VERSION_FILE"
}

MATTN_VER=""
MATTN_BASE=""
MC_VER=""
LOCAL_VER=""
MATTN_REPO_DEFAULT="https://github.com/alvarolm/go-sqlite3.git"
MC_REPO_DEFAULT="https://github.com/utelle/SQLite3MultipleCiphers.git"
MATTN_REPO=""
MC_REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mattn)      MATTN_VER="$2";  shift 2 ;;
        --mattn-base) MATTN_BASE="$2"; shift 2 ;;
        --mc)         MC_VER="$2";     shift 2 ;;
        --version)    LOCAL_VER="$2";  shift 2 ;;
        --mattn-repo) MATTN_REPO="$2"; shift 2 ;;
        --mc-repo)    MC_REPO="$2";    shift 2 ;;
        -h|--help)    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

[ -n "$MATTN_VER" ] || MATTN_VER="$(read_version_field mattn)"
[ -n "$MATTN_BASE" ] || MATTN_BASE="$(read_version_field mattn-base)"
[ -n "$MC_VER"    ] || MC_VER="$(read_version_field mc)"
[ -n "$LOCAL_VER" ] || LOCAL_VER="$(read_version_field local)"
[ -n "$LOCAL_VER" ] || LOCAL_VER="0.1.0"
[ -n "$MATTN_VER" ] || die "--mattn TAG required (no VERSION file to read default from)"
[ -n "$MC_VER"    ] || die "--mc TAG required (no VERSION file to read default from)"
[ -n "$MATTN_REPO" ] || MATTN_REPO="$MATTN_REPO_DEFAULT"
[ -n "$MC_REPO" ] || MC_REPO="$MC_REPO_DEFAULT"

[ -f "$PATCH" ] || die "patch not found: $PATCH"

WORKDIR="$(mktemp -d -t update-sqlite3mc.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# stage_repo SRC TAG OUT_DIR -- copies a checkout (no .git) of TAG into OUT_DIR
# and records the resolved commit sha in OUT_DIR/commit.
stage_repo() {
    local src="$1" tag="$2" out="$3"
    mkdir -p "$out/extracted"
    case "$src" in
        http://*|https://*|git@*)
            log "cloning $src @ $tag"
            git -c advice.detachedHead=false clone --quiet --depth 1 \
                --branch "$tag" "$src" "$out/repo" \
                || die "git clone $src @ $tag failed"
            git -C "$out/repo" rev-parse HEAD > "$out/commit"
            (cd "$out/repo" && git archive HEAD) | tar -x -C "$out/extracted"
            ;;
        *)
            [ -d "$src/.git" ] || die "not a git repo: $src"
            git -C "$src" rev-parse --verify "$tag^{commit}" >/dev/null 2>&1 \
                || die "tag '$tag' not found in $src (try: git -C $src fetch --tags)"
            log "archiving $src @ $tag"
            git -C "$src" rev-parse "$tag^{commit}" > "$out/commit"
            git -C "$src" archive "$tag" | tar -x -C "$out/extracted"
            ;;
    esac
}

stage_repo "$MATTN_REPO" "$MATTN_VER" "$WORKDIR/mattn"
stage_repo "$MC_REPO"    "$MC_VER"    "$WORKDIR/mc"

MATTN_SRC="$WORKDIR/mattn/extracted"
MC_SRC="$WORKDIR/mc/extracted/src"

[ -f "$MATTN_SRC/sqlite3.go" ] || die "mattn checkout missing sqlite3.go"
[ -f "$MC_SRC/sqlite3mc.c"   ] || die "SQLite3MC checkout missing src/sqlite3mc.c"
for f in sqlite3mc.c sqlite3mc.h sqlite3.h sqlite3ext.h sqlite3patched.c rekeyvacuum.c; do
    [ -f "$MC_SRC/$f" ] || die "SQLite3MC checkout missing src/$f"
done

# Wipe and recreate the package subfolder. Repo root (README, scripts/, patches/,
# LICENSE, VERSION, .git/) is left untouched.
log "rebuilding $TARGET/"
rm -rf "$TARGET"
mkdir -p "$TARGET/csrc"

# 1. Copy mattn into $TARGET — exclude tests, README, examples, files we replace
#    from MC, the upstream go.mod (we override below), and nested Go submodules
#    (mattn ships e.g. ./upgrade/ as a separate module).
rsync -a \
    --exclude='*_test.go' \
    --exclude='README.md' \
    --exclude='_example/' \
    --exclude='.git/' \
    --exclude='.github/' \
    --exclude='go.mod' \
    --exclude='go.sum' \
    --exclude='sqlite3-binding.c' \
    --exclude='sqlite3-binding.h' \
    --exclude='sqlite3.h' \
    --exclude='sqlite3ext.h' \
    --chmod=u+w,go+r \
    "$MATTN_SRC/" "$TARGET/"
while IFS= read -r submod_gomod; do
    submod_dir="$(dirname "$submod_gomod")"
    case "$submod_dir" in
        "$TARGET") continue ;;
    esac
    log "removing nested mattn submodule: ${submod_dir#$TARGET/}"
    rm -rf "$submod_dir"
done < <(find "$TARGET" -mindepth 2 -name go.mod)

# 2. Copy SQLite3MC top-level files, renamed into mattn's sqlite3-binding.*
#    convention so sqlite3.go's `#include "sqlite3-binding.h"` resolves.
install -m 0644 "$MC_SRC/sqlite3mc.c"  "$TARGET/sqlite3-binding.c"
install -m 0644 "$MC_SRC/sqlite3mc.h"  "$TARGET/sqlite3-binding.h"
install -m 0644 "$MC_SRC/sqlite3.h"    "$TARGET/sqlite3.h"
install -m 0644 "$MC_SRC/sqlite3ext.h" "$TARGET/sqlite3ext.h"

# 3. Copy SQLite3MC src/ -> csrc/, minus files moved up or otherwise unused.
rsync -a \
    --exclude='shell.c' \
    --exclude='sqlite370.ico' \
    --exclude='sqlite3.c' \
    --exclude='sqlite3ext.h' \
    --exclude='sqlite3mc.c' \
    --exclude='sqlite3mc.def' \
    --exclude='tclsqlite.c' \
    --exclude='windirent.h' \
    --exclude='zlibwrap.h' \
    --chmod=u+w,go+r \
    "$MC_SRC/" "$TARGET/csrc/"

# 3b. Make every csrc/ directory a Go package and blank-import them all from
#     a never-built file in the main package. `go mod vendor` only copies
#     package directories (golang.org/issue/26366), but it resolves imports
#     under ALL build tags — so these stubs get the C sources into consumers'
#     vendor trees while the "vendorkeep" tag keeps them out of every build.
VENDORKEEP="$TARGET/vendorkeep.go"
{
    cat <<EOF
// Code generated by scripts/update.sh; DO NOT EDIT.
//
// Never built (the "vendorkeep" tag is never set): these imports only make
// \`go mod vendor\` treat the csrc/ directories as packages so their C
// sources are copied into consumers' vendor trees (golang.org/issue/26366).

//go:build vendorkeep

package sqlite3

import (
EOF
    while IFS= read -r dir; do
        echo "	_ \"$GO_MODULE_PATH/${dir#$TARGET/}\""
    done < <(find "$TARGET/csrc" -type d | sort)
    echo ")"
} > "$VENDORKEEP"
while IFS= read -r dir; do
    cat > "$dir/vendorkeep.go" <<EOF
// Code generated by scripts/update.sh; DO NOT EDIT.
//
// Never built: only makes this directory a Go package so \`go mod vendor\`
// copies its C sources into consumers' vendor trees (golang.org/issue/26366).

//go:build vendorkeep

package $(basename "$dir")
EOF
done < <(find "$TARGET/csrc" -type d)

# 4. Apply local sqlite3.go patch (paths in the patch are a/b/, base = $TARGET).
log "applying $PATCH"
(cd "$TARGET" && patch --no-backup-if-mismatch -p1 -s < "$PATCH") \
    || die "patch failed — regenerate with scripts/regen-patch.sh after fixing sqlite3.go"

# 5. Write our go.mod (overrides the one from mattn, which we excluded above).
GO_MIN="$(awk '/^go [0-9]+\.[0-9]+/{print $2; exit}' "$MATTN_SRC/go.mod" 2>/dev/null || echo 1.19)"
cat > "$TARGET/go.mod" <<EOF
module $GO_MODULE_PATH

go $GO_MIN
EOF
: > "$TARGET/go.sum"

# 6. Write VERSION stamp at repo root. Pull SQLite version from the freshly-installed
#    header so it can never drift from the actual amalgamation.
SQLITE_VER="$(awk -F'"' '/^#define SQLITE_VERSION /{print $2; exit}' "$TARGET/sqlite3.h")"
[ -n "$SQLITE_VER" ] || die "could not parse SQLITE_VERSION from $TARGET/sqlite3.h"
MATTN_COMMIT="$(cat "$WORKDIR/mattn/commit")"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$VERSION_FILE" <<EOF
local=$LOCAL_VER
mattn=$MATTN_VER
mattn-commit=$MATTN_COMMIT
mattn-base=$MATTN_BASE
mc=$MC_VER
sqlite=$SQLITE_VER
built=$BUILT_AT
EOF

# 7. Smoke build the package subfolder.
log "go build ./... (in $TARGET)"
(cd "$TARGET" && go build ./...) || die "go build failed after rebuild"

log "done: local=$LOCAL_VER mattn=$MATTN_VER@${MATTN_COMMIT:0:8} (base $MATTN_BASE) mc=$MC_VER sqlite=$SQLITE_VER"
log "to publish: git add -A && git commit -m 'v$LOCAL_VER (mattn $MATTN_VER, mc $MC_VER)' && git tag v$LOCAL_VER && git tag sqlite3/v$LOCAL_VER"
