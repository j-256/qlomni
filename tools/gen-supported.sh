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

generate() {
    cat <<'HEADER'
# Supported extensions

Generated from `QLOmni/QLOmni/Info.plist` and `QLOmniExtension/Info.plist`. Do not edit by hand -- run `make supported` to regenerate. See [README.md](README.md) for context.

| Extension | Description |
|-----------|-------------|
HEADER

    extract_host \
        | sort -f \
        | while IFS=$'\t' read -r ext desc; do
            printf '| `.%s` | %s |\n' "$ext" "$desc"
        done
}

generate > "$OUTPUT"
echo "wrote $OUTPUT"
