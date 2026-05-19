#!/bin/bash
# mdls-summary.sh -- compact UTI summary for a list of files.
#
# `mdls` output is verbose and reads from a Spotlight metadata cache. This
# wrapper prints one line per file:
#   <path>  <UTI>  [+plainText | +text | -text]
#
# Caveat: still uses `mdls`, so the cache-staleness from tools/uti.swift
# applies. Use `tools/uti.swift` if you've just changed registrations and
# need a live read. Use this for batch surveys of files you're not actively
# manipulating.

set -u

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <file> [<file> ...]" >&2
    exit 2
fi

for path in "$@"; do
    if [ ! -e "$path" ]; then
        printf '%-40s  %s\n' "$path" "(missing)"
        continue
    fi
    uti="$(mdls -name kMDItemContentType -raw "$path" 2>/dev/null)"
    tree="$(mdls -name kMDItemContentTypeTree "$path" 2>/dev/null | tr -d '\n' | tr -s ' ')"
    if echo "$tree" | grep -q "public.plain-text"; then
        marker="+plainText"
    elif echo "$tree" | grep -q "public.text"; then
        marker="+text"
    else
        marker="-text"
    fi
    printf '%-40s  %-30s  %s\n' "$path" "$uti" "$marker"
done
