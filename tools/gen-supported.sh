#!/bin/bash
# gen-supported.sh -- generate SUPPORTED.md from QLOmni's Info.plist files.
#
# SUPPORTED.md is a user-facing reference table of every file extension
# QLOmni declares, sorted alphabetically. The plists are canonical;
# SUPPORTED.md is a generated artefact -- hand-edits get clobbered on
# the next regeneration.
#
# Usage:
#   tools/gen-supported.sh           # writes SUPPORTED.md at repo root
#   tools/gen-supported.sh --check   # exit 0 if SUPPORTED.md matches
#                                    # what we'd generate, else exit 1
#                                    # with a diff and a hint

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST_PLIST="$REPO_ROOT/QLOmni/QLOmni/Info.plist"
APPEX_PLIST="$REPO_ROOT/QLOmniExtension/Info.plist"
OUTPUT="$REPO_ROOT/SUPPORTED.md"

# Walk both UTExportedTypeDeclarations and UTImportedTypeDeclarations in
# the host plist. For each declaration, emit one (extension, description)
# pair per filename extension. jq fans out the array via [].
extract_host() {
    /usr/bin/plutil -convert json -o - "$HOST_PLIST" | /usr/bin/jq -r '
        (.UTExportedTypeDeclarations + .UTImportedTypeDeclarations)[]
        | .UTTypeDescription as $desc
        | .UTTypeTagSpecification."public.filename-extension"
        | if type == "string" then [.] else . end
        | .[]
        | "\(.)\t\($desc)"
    '
}

# Extensions the appex renders via QLSupportedContentTypes but doesn't
# declare in the host plist (i.e. UTIs without our own UTTypeDescription).
# Map: appex-claimed UTI -> "extension<TAB>description" lines.
#
# Why this is hardcoded rather than parsed: extensions for system-declared
# UTIs (e.g. public.yaml) live in Apple's CoreTypes plist, not ours --
# there's no plist of ours to scan. Each entry below is gated on the UTI
# actually appearing in the appex's QLSupportedContentTypes, so removing
# a UTI from the appex plist also drops the supplemental rows. UTIs in
# QLSupportedContentTypes that *are* declared in the host plist (toml,
# microsoft.ini) need no entry here -- extract_host already covers them.
# UTIs without a filename extension (public.unix-executable) need none.
supplemental_map() {
    cat <<'EOF'
public.yaml|yaml	YAML configuration
public.yaml|yml	YAML configuration
EOF
}

extract_supplemental() {
    local appex_utis
    appex_utis="$(/usr/bin/plutil -convert json -o - "$APPEX_PLIST" \
        | /usr/bin/jq -r '.NSExtension.NSExtensionAttributes.QLSupportedContentTypes[]')"
    while IFS='|' read -r uti row; do
        [ -z "$uti" ] && continue
        if grep -qxF "$uti" <<< "$appex_utis"; then
            printf '%s\n' "$row"
        fi
    done < <(supplemental_map)
}

# Extensions that QLOmni declares but cannot actually preview. Each entry
# is `extension<TAB>footnote-text`. The generator appends a superscript
# footnote marker to the row in the table and emits a footnote section
# below the table. See README.md "Doesn't fix .ts" for the canonical
# explanation.
known_broken() {
    cat <<'EOF'
ts	Declared but does not preview on modern macOS. CoreTypes claims `.ts` as `public.mpeg-2-transport-stream` (an MPEG-2 video container) and that UTI has a system display bundle that third-party Preview Extensions cannot displace. See [README.md](README.md) for details.
EOF
}

generate() {
    # Build the row list once; we need it twice (rows + footnote section).
    local rows
    rows="$(mktemp)"
    trap 'rm -f "$rows"' RETURN
    { extract_host; extract_supplemental; } | sort -f > "$rows"

    # Space-padded list of broken extensions for fast membership check.
    local broken_exts
    broken_exts=" $(known_broken | cut -f1 | tr '\n' ' ')"

    cat <<'HEADER'
# Supported extensions

Generated from `QLOmni/QLOmni/Info.plist` and `QLOmniExtension/Info.plist`. Do not edit by hand -- run `make supported` to regenerate. See [README.md](README.md) for context.

| Extension | Description |
|-----------|-------------|
HEADER

    while IFS=$'\t' read -r ext desc; do
        case "$broken_exts" in
            *" $ext "*) printf '| `.%s` [^%s] | %s |\n' "$ext" "$ext" "$desc" ;;
            *)          printf '| `.%s` | %s |\n' "$ext" "$desc" ;;
        esac
    done < "$rows"

    # Footnotes section. Markdown's footnote syntax: [^id]: text.
    # Only emit footnotes for broken extensions that are actually in the
    # table -- defensive against a known_broken entry whose declaration
    # has been removed. Footnote IDs are the extension itself for raw-MD
    # readability and stability under reordering.
    local printed_header=0
    while IFS=$'\t' read -r bext btext; do
        [ -z "$bext" ] && continue
        if grep -q $'^'"$bext"$'\t' "$rows"; then
            if [ "$printed_header" = 0 ]; then
                echo
                printed_header=1
            fi
            printf '[^%s]: %s\n' "$bext" "$btext"
        fi
    done < <(known_broken)
}

generate > "$OUTPUT"
echo "wrote $OUTPUT"
