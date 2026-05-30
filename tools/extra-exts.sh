#!/bin/bash
# extra-exts.sh -- inject extra UTI declarations into a built QLOmni bundle.
#
# Used by `make build` / `make install` when EXTRA_EXTS is set, so build-from-
# source users can declare personal file extensions that aren't worth shipping
# upstream. See README.md "Building with extra extensions".
#
# Usage:
#   tools/extra-exts.sh validate <extra-exts-file>
#       Validates the file format and checks for collisions against the
#       committed host plist. No mutations. Exit 0 if valid.
#
#   tools/extra-exts.sh apply <extra-exts-file> <plist-path>
#       Idempotently injects entries into <plist-path> as
#       UTExportedTypeDeclarations. Strips any pre-existing
#       user.qlomni-ext.* entries first, so re-running with a different
#       file (or no file) cleanly resets state.
#
# Input file format:
#   ext | Description
#   # comments and blank lines ignored
#
# `ext` is the bare filename extension (no leading dot). Each entry produces
# a plain-text-conforming UTI named `user.qlomni-ext.<ext>` -- the prefix
# guarantees no collision with the project's own user.* identifiers.
#
# Why a separate prefix: extras live only in your local bundle and never
# touch the committed plist. Keeping them in their own namespace also makes
# `apply` reversible -- the strip-pre-existing step can target the prefix
# without false positives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST_PLIST="$REPO_ROOT/QLOmni/QLOmni/Info.plist"
EXTRA_PREFIX="user.qlomni-ext."

usage() {
    cat <<EOF >&2
usage: $0 validate <extra-exts-file>
       $0 apply    <extra-exts-file> <plist-path>
       $0 strip    <plist-path>
EOF
    exit 2
}

# Parse the input file into lines of "ext<TAB>desc" on stdout. Errors out
# on invalid extension chars, missing description, duplicates within the
# file, or collisions with the committed plist.
parse_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "error: $file: no such file" >&2
        exit 1
    fi
    local lineno=0
    local seen=" "
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # Strip leading and trailing whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            ""|"#"*) continue ;;
        esac
        case "$line" in
            *"|"*) ;;
            *) echo "error: $file:$lineno: missing '|' separator (expected: ext | Description)" >&2; exit 1 ;;
        esac
        local ext="${line%%|*}"
        local desc="${line#*|}"
        ext="${ext%"${ext##*[![:space:]]}"}"
        ext="${ext#"${ext%%[![:space:]]*}"}"
        desc="${desc%"${desc##*[![:space:]]}"}"
        desc="${desc#"${desc%%[![:space:]]*}"}"
        case "$ext" in
            "")  echo "error: $file:$lineno: empty extension" >&2; exit 1 ;;
            .*)  echo "error: $file:$lineno: extension '$ext' must not start with a dot" >&2; exit 1 ;;
        esac
        if ! [[ "$ext" =~ ^[A-Za-z0-9_-]+$ ]]; then
            echo "error: $file:$lineno: invalid extension '$ext' (allowed: A-Z a-z 0-9 _ -)" >&2
            exit 1
        fi
        if [ -z "$desc" ]; then
            echo "error: $file:$lineno: missing description after '|' for '$ext'" >&2
            exit 1
        fi
        case "$seen" in
            *" $ext "*) echo "error: $file:$lineno: extension '$ext' listed more than once" >&2; exit 1 ;;
        esac
        seen="$seen$ext "
        if plist_has_ext "$HOST_PLIST" "$ext"; then
            echo "error: $file:$lineno: extension '$ext' is already declared in QLOmni/QLOmni/Info.plist" >&2
            echo "       (refusing to override; remove '$ext' from your extras file)" >&2
            exit 1
        fi
        printf '%s\t%s\n' "$ext" "$desc"
    done < "$file"
}

# Returns 0 if `plist` already declares `ext` under either declarations array.
plist_has_ext() {
    local plist="$1"
    local ext="$2"
    /usr/bin/plutil -convert json -o - "$plist" \
        | /usr/bin/jq -e --arg ext "$ext" '
            [
                ((.UTExportedTypeDeclarations // []) + (.UTImportedTypeDeclarations // []))[]
                | .UTTypeTagSpecification."public.filename-extension"
                | (if type == "string" then [.] else . end)
                | .[]
            ]
            | any(. == $ext)
        ' >/dev/null 2>&1
}

# Strip any existing user.qlomni-ext.* entries from the plist, in place.
# Preserves the plist's on-disk format (xml1 vs binary1).
strip_extras() {
    local plist="$1"
    local fmt
    fmt="$(detect_format "$plist")"
    local tmp_json
    tmp_json="$(mktemp)"
    /usr/bin/plutil -convert json -o - "$plist" \
        | /usr/bin/jq --arg pfx "$EXTRA_PREFIX" '
            if .UTExportedTypeDeclarations then
                .UTExportedTypeDeclarations |= map(
                    select((.UTTypeIdentifier // "") | startswith($pfx) | not)
                )
            else . end
        ' > "$tmp_json"
    /usr/bin/plutil -convert "$fmt" -o "$plist" "$tmp_json"
    rm -f "$tmp_json"
}

# Detect plist format so we can write back in the same shape. xcodebuild
# emits binary1 for bundle Info.plist; the source plist is xml1.
detect_format() {
    local plist="$1"
    case "$(/usr/bin/file -b "$plist")" in
        *"XML"*|*"ASCII text"*) echo xml1 ;;
        *)                       echo binary1 ;;
    esac
}

# Append one user.qlomni-ext.<ext> entry to UTExportedTypeDeclarations.
insert_entry() {
    local plist="$1"
    local ext="$2"
    local desc="$3"
    local uti="${EXTRA_PREFIX}${ext}"
    local json
    json="$(/usr/bin/jq -nc \
        --arg uti "$uti" --arg desc "$desc" --arg ext "$ext" '
            {
                UTTypeIdentifier: $uti,
                UTTypeDescription: $desc,
                UTTypeConformsTo: ["public.plain-text"],
                UTTypeTagSpecification: {"public.filename-extension": [$ext]}
            }')"
    # Insert at index 0; ordering doesn't affect Launch Services dispatch.
    /usr/bin/plutil -insert "UTExportedTypeDeclarations.0" -json "$json" "$plist"
}

case "${1:-}" in
    validate)
        [ $# -eq 2 ] || usage
        entries="$(parse_file "$2")"
        if [ -z "$entries" ]; then
            echo "ok (no entries -- file is empty or all comments)"
            exit 0
        fi
        n=0
        while IFS=$'\t' read -r ext desc; do
            [ -z "$ext" ] && continue
            echo "  .$ext -> ${EXTRA_PREFIX}${ext} ($desc)"
            n=$((n + 1))
        done <<< "$entries"
        echo "ok ($n entries)"
        ;;
    strip)
        [ $# -eq 2 ] || usage
        plist="$2"
        if [ ! -f "$plist" ]; then
            echo "error: $plist: no such file" >&2
            exit 1
        fi
        strip_extras "$plist"
        echo "stripped any qlomni-ext extras from $plist"
        ;;
    apply)
        [ $# -eq 3 ] || usage
        file="$2"
        plist="$3"
        if [ ! -f "$plist" ]; then
            echo "error: $plist: no such file" >&2
            exit 1
        fi
        entries="$(parse_file "$file")"
        strip_extras "$plist"
        if [ -z "$entries" ]; then
            echo "stripped any prior extras from $plist (no new entries to add)"
            exit 0
        fi
        n=0
        while IFS=$'\t' read -r ext desc; do
            [ -z "$ext" ] && continue
            insert_entry "$plist" "$ext" "$desc"
            n=$((n + 1))
        done <<< "$entries"
        echo "applied $n extra extension(s) to $plist"
        ;;
    *)
        usage
        ;;
esac
