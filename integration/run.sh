#!/bin/bash
# Integration tests for QLOmni.
#
# Asserts that every file extension declared in QLOmni's Info.plist resolves to
# a sensible UTI on this machine. Requires QLOmni to be installed first
# (`make install`); checks pluginkit registration as a precondition.
#
# Two kinds of assertion:
#
#   assert_strict <fixture> <expected-uti>
#     QLOmni *exports* this UTI (user.*). It must resolve exactly as declared
#     -- if not, our export was overridden or never registered.
#
#   assert_lenient <fixture> <preferred-uti>
#     This extension is contested -- another declarer (often Apple's
#     CoreTypes or Xcode) may legitimately claim it with a different UTI.
#     We accept any non-dyn.* UTI and report the winner. See DESIGN.md
#     ("Extension collisions across declarers") for precedence rules.
#
# Note: rendering correctness (does QuickLook actually render text for these
# UTIs?) is not checked here -- there's no headless way to assert that. Run
# `qlmanage -p <fixture>` manually to verify rendering.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
EXTENSION_ID="dev.j-256.qlomni.QLOmniExtension"

pass=0
fail=0
failed_cases=()

ok()    { echo "ok   - $1"; pass=$((pass + 1)); }
notok() { echo "not ok - $1"; fail=$((fail + 1)); failed_cases+=("$1"); }

if ! pluginkit -m -p com.apple.quicklook.preview 2>/dev/null | grep -q "^+.*$EXTENSION_ID"; then
    echo "QLOmni is not installed/enabled."
    echo "Looked for an entry beginning with '+' for $EXTENSION_ID in:"
    echo "  pluginkit -m -p com.apple.quicklook.preview"
    echo "Run 'make install' first."
    exit 2
fi

# mdls reads from Spotlight metadata which can lag a freshly-written file.
# Retry briefly to give mds time to index. -raw prints just the value with no header.
read_uti() {
    local path="$1"
    local actual=""
    for _ in 1 2 3 4 5; do
        actual="$(mdls -name kMDItemContentType -raw "$path" 2>/dev/null)"
        case "$actual" in
            ""|"(null)"|dyn.*) sleep 0.5 ;;
            *) printf '%s' "$actual"; return ;;
        esac
    done
    printf '%s' "$actual"
}

assert_strict() {
    local fixture="$1"
    local expected="$2"
    local path="$FIXTURES_DIR/$fixture"

    if [ ! -e "$path" ]; then
        notok "$fixture (fixture file missing at $path)"
        return
    fi

    local actual
    actual="$(read_uti "$path")"
    if [ "$actual" = "$expected" ]; then
        ok "$fixture -> $expected"
    else
        notok "$fixture: expected '$expected', got '$actual'"
    fi
}

assert_lenient() {
    local fixture="$1"
    local preferred="$2"
    local path="$FIXTURES_DIR/$fixture"

    if [ ! -e "$path" ]; then
        notok "$fixture (fixture file missing at $path)"
        return
    fi

    local actual
    actual="$(read_uti "$path")"
    case "$actual" in
        "")
            notok "$fixture: no UTI returned"
            ;;
        dyn.*)
            notok "$fixture: synthetic '$actual' (no declarer reached this file -- our import isn't registered)"
            ;;
        "$preferred")
            ok "$fixture -> $preferred (our import won)"
            ;;
        *)
            ok "$fixture -> $actual (another declarer won; we'd have used $preferred)"
            ;;
    esac
}

# Strict: extensions where no other declarer is expected to compete with us.
# QLOmni's declaration must win exactly, otherwise something is broken.
assert_strict sample.jsonc           user.jsonc
assert_strict sample.code-workspace  user.vscode-workspace
assert_strict sample.properties      user.properties
assert_strict sample.jsx             user.jsx
assert_strict sample.env             user.env
assert_strict sample.editorconfig    user.editorconfig
assert_strict sample.tf              user.terraform
assert_strict sample.tfvars          user.terraform
assert_strict sample.graphql         user.graphql
assert_strict sample.gql             user.graphql
assert_strict sample.err             user.err
assert_strict sample.out             user.out
assert_strict sample.yml             public.yaml
assert_strict extensionless          public.unix-executable

# Lenient: extensions where another app may reasonably also claim them. We
# accept losing to a real (non-dyn.*) UTI -- the design is that we act as a
# backup for users who don't have the competing app installed. Each line
# notes who we expect might compete.
assert_lenient sample.gs             user.gs                       # vs OpenGL geometry shader (Xcode)
assert_lenient sample.sql            org.iso.sql                   # vs SQL editors / IDEs
assert_lenient sample.toml           public.toml                   # vs Xcode (declares public.toml itself)
assert_lenient sample.ts             com.microsoft.typescript      # vs CoreTypes (mpeg-2-transport-stream)
assert_lenient sample.tsx            com.microsoft.typescript      # vs Xcode
assert_lenient sample.proto          public.protobuf-source        # vs Xcode
assert_lenient sample.md             net.daringfireball.markdown   # vs Xcode / markdown editors

echo
echo "$pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    echo "Failed cases:"
    for c in "${failed_cases[@]}"; do
        echo "  - $c"
    done
    exit 1
fi
