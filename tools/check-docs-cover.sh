#!/bin/bash
set -eu

cover_path="docs/screenshots/cover.png"
max_cover_bytes=8388608
png_signature="89504e470d0a1a0a"

if [ ! -f "$cover_path" ]; then
    echo "Documentation cover is missing: $cover_path" >&2
    exit 1
fi

cover_bytes="$(wc -c < "$cover_path" | tr -d '[:space:]')"
if [ "$cover_bytes" -gt "$max_cover_bytes" ]; then
    echo "Documentation cover exceeds the size limit" >&2
    exit 1
fi

actual_signature="$(od -An -tx1 -N8 "$cover_path" | tr -d '[:space:]')"
if [ "$actual_signature" != "$png_signature" ]; then
    echo "Documentation cover is not a PNG" >&2
    exit 1
fi

echo "Documentation cover is a valid PNG"
