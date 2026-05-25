#!/bin/bash
# audit-collisions.sh -- find non-QLOmni declarers for the extensions QLOmni claims.
#
# QLOmni declares ~65 extensions in QLOmni/QLOmni/Info.plist. macOS Launch
# Services may also have an active declaration for the same extension from
# Apple's CoreTypes, Xcode, or other installed apps. When that happens, the
# precedence rules described in DESIGN.md ("Extension collisions across
# declarers") decide who wins -- usually `apple-internal` claims beat ours.
#
# This script scans `lsregister -dump` and reports any extension QLOmni
# declares that ALSO has an active claim from a different bundle. Output is
# silent on clean extensions; only contested ones get a section with the
# competing claim's bundle, UTI, and flags.
#
# Exit codes:
#   0 -- clean (no non-QLOmni declarers found for any of our extensions)
#   1 -- one or more contested extensions
#   2 -- usage error
#
# Usage:
#   tools/audit-collisions.sh
#
# Caveat: this reflects the LS state on THIS machine. An extension that
# looks clean here may collide on a Mac with a different app installed.
# For a fixed precedence question on this machine, this script is
# authoritative; for a "will my package conflict with Xcode?" question,
# only an audit on a Mac with Xcode installed answers it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST_PLIST="$REPO_ROOT/QLOmni/QLOmni/Info.plist"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Output goes into two tiers:
#   "Different-UTI conflicts" -- a real divergence; another bundle claims the
#       extension under a UTI we don't know about. The file's effective UTI on
#       this machine may not be one of ours.
#   "Same-UTI imports" -- another bundle claims the same UTI we do (e.g. Xcode
#       imports public.toml, just like us). No effective conflict; the system
#       just picks the higher-precedence registration. Surfaced for awareness.

if [ "$#" -ne 0 ]; then
    echo "usage: $0" >&2
    exit 2
fi

if [ ! -x "$LSREGISTER" ]; then
    echo "error: lsregister not found at $LSREGISTER" >&2
    exit 2
fi

# Pull every (extension, UTI) pair declared by QLOmni's host plist (both
# UTExportedTypeDeclarations and UTImportedTypeDeclarations).
ext_uti_pairs="$(/usr/bin/plutil -convert json -o - "$HOST_PLIST" | /usr/bin/jq -r '
    (.UTExportedTypeDeclarations + .UTImportedTypeDeclarations)[]
    | .UTTypeIdentifier as $uti
    | .UTTypeTagSpecification."public.filename-extension"
    | if type == "string" then [.] else . end
    | .[]
    | "\(.)\t\($uti)"
' | sort -u)"

extensions="$(echo "$ext_uti_pairs" | cut -f1 | sort -u)"

# Single dump, scanned per-extension. The dump is large (~280k lines on a
# typical dev machine) but this is a one-shot audit, not a hot path.
dump="$(mktemp)"
trap 'rm -f "$dump"' EXIT
"$LSREGISTER" -dump > "$dump" 2>/dev/null

# For each extension, find every record block whose `tags:` line contains
# that extension AND whose `flags:` line includes the word "active". For
# each such block, extract bundle name, UTI, and flags. Skip records whose
# bundle is QLOmni -- those are our own claims. Anything left is a foreign
# active claim, classified by whether its UTI matches ours or differs.
different_uti_conflicts=""
same_uti_neighbors=""
for ext in $extensions; do
    our_utis="$(echo "$ext_uti_pairs" | awk -v e="$ext" -F'\t' '$1 == e { print $2 }')"
    # Records are separated by 80-dash banners in the dump. RS uses the
    # banner; per-record matching uses awk regexes.
    rivals="$(awk -v ext="$ext" '
        BEGIN { RS = "--------------------------------------------------------------------------------" }
        # Match records where the tags line lists this extension AND flags has "active".
        # \\b unsupported in mawk; use [, \n] / non-letter boundary to avoid .test matching .testify etc.
        $0 ~ "tags:[[:space:]]+([^,\n]+, *)*\\." ext "([, \n]|$)" {
            has_active = 0
            bundle = ""
            uti = ""
            flags = ""
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) {
                line = lines[i]
                if (line ~ /^[[:space:]]*flags:/ && line ~ /[[:space:]]active[[:space:]]/) {
                    has_active = 1
                    sub(/^[[:space:]]*flags:[[:space:]]+/, "", line)
                    flags = line
                }
                if (line ~ /^[[:space:]]*bundle:/) {
                    sub(/^[[:space:]]*bundle:[[:space:]]+/, "", line)
                    bundle = line
                }
                if (line ~ /^[[:space:]]*uti:/) {
                    sub(/^[[:space:]]*uti:[[:space:]]+/, "", line)
                    uti = line
                }
            }
            if (has_active && bundle !~ /^QLOmni([[:space:]]|$)/) {
                printf "%s\t%s\t%s\n", bundle, uti, flags
            }
        }
    ' "$dump" | sort -u)"

    if [ -z "$rivals" ]; then
        continue
    fi

    # Classify each rival as same-UTI (we and they claim the same UTI) or
    # different-UTI (genuine divergence). A single extension can produce both
    # kinds of rival entries.
    different_for_ext=""
    same_for_ext=""
    while IFS=$'\t' read -r bundle uti flags; do
        if echo "$our_utis" | grep -qxF "$uti"; then
            same_for_ext="$same_for_ext  bundle: $bundle"$'\n'"  uti:    $uti"$'\n'"  flags:  $flags"$'\n\n'
        else
            different_for_ext="$different_for_ext  bundle: $bundle"$'\n'"  uti:    $uti"$'\n'"  flags:  $flags"$'\n\n'
        fi
    done <<< "$rivals"

    if [ -n "$different_for_ext" ]; then
        different_uti_conflicts="${different_uti_conflicts}=== .$ext ===\n$different_for_ext"
    fi
    if [ -n "$same_for_ext" ]; then
        same_uti_neighbors="${same_uti_neighbors}=== .$ext ===\n$same_for_ext"
    fi
done

ext_count=$(echo "$extensions" | wc -l | tr -d ' ')

if [ -z "$different_uti_conflicts" ] && [ -z "$same_uti_neighbors" ]; then
    echo "No collisions: all $ext_count declared extensions are uncontested by other active LS declarers on this machine."
    exit 0
fi

if [ -n "$different_uti_conflicts" ]; then
    echo "## Different-UTI conflicts"
    echo "Another bundle claims this extension with a UTI we don't declare. Effective UTI on this machine"
    echo "may not be ours; see DESIGN.md (Extension collisions across declarers) for precedence rules."
    echo
    printf '%b' "$different_uti_conflicts"
fi

if [ -n "$same_uti_neighbors" ]; then
    echo "## Same-UTI imports (informational)"
    echo "Another bundle claims the same UTI we do. No effective conflict -- the higher-precedence"
    echo "registration wins, but routing reaches our UTI either way."
    echo
    printf '%b' "$same_uti_neighbors"
fi

if [ -n "$different_uti_conflicts" ]; then
    exit 1
fi
exit 0
