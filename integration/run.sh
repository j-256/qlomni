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
assert_strict sample.har             user.har
assert_strict sample.properties      user.properties
assert_strict sample.jsx             user.jsx
assert_strict sample.editorconfig    user.editorconfig
assert_strict sample.tf              user.terraform
assert_strict sample.tfvars          user.terraform
assert_strict sample.graphql         user.graphql
assert_strict sample.gql             user.graphql
assert_strict sample.err             user.err
assert_strict sample.out             user.out
assert_strict sample.yml             public.yaml
assert_strict sample.yaml            public.yaml
assert_strict extensionless          public.unix-executable
assert_strict extensionless-nonexec  public.data
assert_strict .bashrc                public.data
assert_strict sample.css             public.css
assert_strict sample.rs              user.rust
assert_strict sample.go              user.go-source
assert_strict sample.kt              user.kotlin
assert_strict sample.kts             user.kotlin
assert_strict sample.cs              user.csharp
assert_strict sample.scala           user.scala
assert_strict sample.dart            user.dart
assert_strict sample.vue             user.vue
assert_strict sample.svelte          user.svelte
assert_strict sample.sass            user.sass
assert_strict sample.scss            user.sass
assert_strict sample.less            user.less
assert_strict sample.hcl             user.hcl
assert_strict sample.clj             user.clojure
assert_strict sample.cljs            user.clojure
assert_strict sample.cljc            user.clojure
assert_strict sample.hs              user.haskell
assert_strict sample.ps1             user.powershell
assert_strict sample.psm1            user.powershell
assert_strict sample.ex              user.elixir
assert_strict sample.coffee          user.coffeescript
assert_strict sample.groovy          user.groovy
assert_strict sample.fish            user.fish
assert_strict sample.feature         user.gherkin
assert_strict sample.hbs             user.handlebars
assert_strict sample.handlebars      user.handlebars
assert_strict sample.cjs             user.cjs
assert_strict sample.awk             user.awk
assert_strict sample.sed             user.sed
assert_strict sample.vim             user.vim
assert_strict sample.conf            user.conf
# Environment-variant suffixes -- in practice always trail a real config
# (.env.production, docker-compose.yml.example, nginx.conf.staging, etc.)
# and never stand alone as files of their own. See DESIGN.md
# ("Environment-variant suffixes") for which extensions are included and why.
assert_strict sample.example         user.example
assert_strict sample.local           user.local
assert_strict sample.development     user.development
assert_strict sample.dev             user.dev
assert_strict sample.production      user.production
assert_strict sample.prod            user.prod
assert_strict sample.staging         user.staging
assert_strict sample.test            user.test

# Lenient: extensions where another app may reasonably also claim them. We
# accept losing to a real (non-dyn.*) UTI -- the design is that we act as a
# backup for users who don't have the competing app installed. Each line
# notes who we expect might compete.
assert_lenient sample.gs             user.gs                       # vs Xcode's org.khronos.glsl.geometry-shader (also conforms to public.plain-text, so previews either way)
assert_lenient sample.sql            org.iso.sql                   # vs SQL editors / IDEs
assert_lenient sample.toml           public.toml                   # vs Xcode (declares public.toml itself)
assert_lenient sample.ts             com.microsoft.typescript      # vs CoreTypes (mpeg-2-transport-stream)
assert_lenient sample.tsx            com.microsoft.typescript      # vs Xcode
assert_lenient sample.proto          public.protobuf-source        # vs Xcode
assert_lenient sample.md             net.daringfireball.markdown   # vs Xcode / markdown editors
assert_lenient sample.markdown       net.daringfireball.markdown   # vs Xcode / markdown editors
assert_lenient sample.ini            com.microsoft.ini             # vs Xcode (declares com.microsoft.ini itself)

echo
echo "$pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    echo "Failed cases:"
    for c in "${failed_cases[@]}"; do
        echo "  - $c"
    done
    exit 1
fi
