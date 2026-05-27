#!/bin/bash
# check-release-integration.sh -- predict whether `make release` would run
# integration tests, given the current state of the repo and INTEGRATION env.
#
# Mirrors the decision logic in the release: target. `make release` calls this
# to make its decision; `make check-release-integration` calls it as a
# read-only "what would happen?" probe.
#
# Inputs:
#   INTEGRATION  (env, optional) -- "1" forces yes, "0" forces no, "" auto.
#   UTI_SURFACE  (env, required) -- space-separated paths whose changes since
#                                   the previous tag trigger integration.
#
# Output: a one-line decision (`==> integration tests: yes/no (reason)`) plus
# context lines on stdout. Exit 0 if integration would run, 1 if skipped, 2
# on usage error.

set -u

if [ -z "${UTI_SURFACE:-}" ]; then
    echo "error: UTI_SURFACE not set" >&2
    exit 2
fi

prev_tag="$(git describe --tags --abbrev=0 --match='v*' 2>/dev/null || true)"
run_integration=""
reason=""
extra=""
# shellcheck disable=SC2086 -- $UTI_SURFACE is intentionally word-split
case "${INTEGRATION:-}" in
    1)
        run_integration=yes
        reason="forced via INTEGRATION=1"
        ;;
    0)
        run_integration=no
        reason="skipped via INTEGRATION=0"
        if [ -n "$prev_tag" ] && [ -n "$(git diff --name-only "$prev_tag..HEAD" -- $UTI_SURFACE)" ]; then
            extra="WARNING: UTI surface changed since $prev_tag but integration tests would be skipped."
        fi
        ;;
    "")
        if [ -z "$prev_tag" ]; then
            run_integration=yes
            reason="first release; no previous tag to diff against"
        else
            changed="$(git diff --name-only "$prev_tag..HEAD" -- $UTI_SURFACE)"
            if [ -n "$changed" ]; then
                run_integration=yes
                reason="UTI surface changed since $prev_tag"
                extra="changed:"$'\n'"$(echo "$changed" | sed 's/^/      /')"
            else
                run_integration=no
                reason="no UTI surface changes since $prev_tag"
            fi
        fi
        ;;
    *)
        echo "error: INTEGRATION='${INTEGRATION}' must be 0, 1, or unset" >&2
        exit 2
        ;;
esac

echo "==> integration tests: $run_integration ($reason)"
if [ -n "$extra" ]; then
    printf '    %s\n' "$extra"
fi

[ "$run_integration" = yes ]
