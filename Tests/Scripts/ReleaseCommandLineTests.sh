#!/bin/bash

set -eu

readonly EXPECTED_SUCCESS=0
readonly EXPECTED_USAGE=2
readonly EXPECTED_DEPENDENCY=3

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/../.." && pwd)
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/qlomni-release-tests.XXXXXX")
empty_path="$test_directory/empty-path"
stdout_path="$test_directory/stdout"
stderr_path="$test_directory/stderr"
mkdir -p "$empty_path"
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM

last_status=0

run_command() {
    set +e
    "$@" >"$stdout_path" 2>"$stderr_path"
    last_status=$?
    set -e
}

fail() {
    printf 'ReleaseCommandLineTests: %s\n' "$1" >&2
    printf '%s\n' '--- stdout ---' >&2
    sed 's/^/  /' "$stdout_path" >&2
    printf '%s\n' '--- stderr ---' >&2
    sed 's/^/  /' "$stderr_path" >&2
    exit 1
}

assert_status() {
    local expected_status

    expected_status=$1
    [ "$last_status" -eq "$expected_status" ] || fail "expected status $expected_status, got $last_status"
}

assert_stdout_present() {
    [ -s "$stdout_path" ] || fail 'expected stdout'
}

assert_stdout_empty() {
    [ ! -s "$stdout_path" ] || fail 'expected empty stdout'
}

assert_stderr_empty() {
    [ ! -s "$stderr_path" ] || fail 'expected empty stderr'
}

assert_stderr_contains() {
    grep -Fq -- "$1" "$stderr_path" || fail "expected stderr to contain: $1"
}

assert_stdout_contains() {
    grep -Fq -- "$1" "$stdout_path" || fail "expected stdout to contain: $1"
}

for command_name in package-release release verify-release; do
    command_path="$repository_root/scripts/$command_name"

    run_command "$command_path" -h
    assert_status "$EXPECTED_SUCCESS"
    assert_stdout_present
    assert_stderr_empty

    run_command "$command_path" --help
    assert_status "$EXPECTED_SUCCESS"
    assert_stdout_present
    assert_stderr_empty

    run_command "$command_path" --unknown-option
    assert_status "$EXPECTED_USAGE"
    assert_stdout_empty
    assert_stderr_contains 'unknown option'
done

run_command "$repository_root/scripts/package-release"
assert_status "$EXPECTED_USAGE"
assert_stderr_contains '--keychain-profile is required'

run_command "$repository_root/scripts/package-release" --keychain-profile=example
assert_status "$EXPECTED_USAGE"
assert_stderr_contains '--signing-identity is required'

run_command "$repository_root/scripts/package-release" \
    --keychain-profile=example \
    --signing-identity=- \
    --team-id=EXAMPLETEAM \
    --expected-version=1.10.0
assert_status "$EXPECTED_USAGE"
assert_stderr_contains 'ad-hoc signing is not allowed'

run_command "$repository_root/scripts/package-release" --app=
assert_status "$EXPECTED_USAGE"
assert_stderr_contains '--app requires a value'

run_command "$repository_root/scripts/verify-release"
assert_status "$EXPECTED_USAGE"
assert_stderr_contains 'APP_OR_ZIP is required'

run_command "$repository_root/scripts/verify-release" example.app
assert_status "$EXPECTED_USAGE"
assert_stderr_contains '--team-id is required'

run_command "$repository_root/scripts/verify-release" --ad-hoc --pre-notarization example.app
assert_status "$EXPECTED_USAGE"
assert_stderr_contains 'cannot be combined'

run_command "$repository_root/scripts/release"
assert_status "$EXPECTED_USAGE"
assert_stderr_contains '--version is required'

run_command "$repository_root/scripts/release" --version=1.2
assert_status "$EXPECTED_USAGE"
assert_stderr_contains 'version must be X.Y.Z'

fake_app="$test_directory/Fake App.app"
mkdir -p "$fake_app"

run_command env PATH="$empty_path" \
    "$repository_root/scripts/package-release" \
    --app="$fake_app" \
    --output="$test_directory/release.zip" \
    --keychain-profile=example \
    --signing-identity='Developer ID Application: Example' \
    --team-id=EXAMPLETEAM \
    --expected-version=1.10.0
assert_status "$EXPECTED_DEPENDENCY"
assert_stderr_contains 'required command not found'

run_command env PATH="$empty_path" \
    "$repository_root/scripts/verify-release" \
    --ad-hoc \
    --expected-version=1.10.0 \
    "$fake_app"
assert_status "$EXPECTED_DEPENDENCY"
assert_stderr_contains 'required command not found'

mock_bin="$test_directory/mock-bin"
mock_log="$test_directory/mock.log"
mock_tool="$mock_bin/mock-tool"
mkdir -p "$mock_bin"

cat >"$mock_tool" <<'EOF'
#!/bin/bash

set -eu

tool_name=${0##*/}
last_argument=${!#}

case "$tool_name" in
    codesign)
        case " $* " in
            *' --sign '*)
                printf 'sign\t%s\n' "$*" >>"$MOCK_LOG"
                exit 0
                ;;
        esac
        if [ "${1:-}" = '-d' ]; then
            case " $* " in
                *' --entitlements '*)
                    entitlement_output=''
                    previous=''
                    for argument in "$@"; do
                        if [ "$previous" = '--entitlements' ]; then
                            entitlement_output=$argument
                            break
                        fi
                        previous=$argument
                    done
                    cat >"$entitlement_output" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-only</key><true/>
</dict></plist>
PLIST
                    exit 0
                    ;;
                *)
                    if [ "${MOCK_SIGNATURE_KIND:-developer-id}" = 'adhoc' ]; then
                        printf 'Signature=adhoc\n' >&2
                    else
                        printf 'Authority=Developer ID Application: Example\n' >&2
                        printf 'TeamIdentifier=EXAMPLETEAM\n' >&2
                        printf 'CodeDirectory flags=0x10000(runtime)\n' >&2
                        printf 'Timestamp=Sep 4, 2026\n' >&2
                    fi
                    exit 0
                    ;;
            esac
        fi
        exit 0
        ;;
    ditto)
        case " $* " in
            *' -x -k '*)
                extracted_app="$last_argument/QLOmni.app"
                mkdir -p \
                    "$extracted_app/Contents/MacOS" \
                    "$extracted_app/Contents/PlugIns/QLOmniExtension.appex/Contents/MacOS"
                : >"$extracted_app/Contents/Info.plist"
                : >"$extracted_app/Contents/MacOS/QLOmni"
                : >"$extracted_app/Contents/PlugIns/QLOmniExtension.appex/Contents/Info.plist"
                : >"$extracted_app/Contents/PlugIns/QLOmniExtension.appex/Contents/MacOS/QLOmniExtension"
                ;;
            *' -c -k '*) : >"$last_argument" ;;
            *) exit 1 ;;
        esac
        ;;
    lipo) printf 'x86_64 arm64\n' ;;
    plutil)
        [ "${1:-}" = '-lint' ] && exit 0
        key=${2:-}
        case "$key" in
            CFBundleIdentifier)
                case "$last_argument" in
                    *QLOmniExtension.appex*) printf 'dev.j-256.qlomni.QLOmniExtension\n' ;;
                    *) printf 'dev.j-256.qlomni\n' ;;
                esac
                ;;
            CFBundleShortVersionString) printf '%s\n' "${MOCK_VERSION:-1.10.0}" ;;
            CFBundleVersion) printf '1\n' ;;
            LSMinimumSystemVersion) printf '12.0\n' ;;
            status) printf '%s\n' "${MOCK_NOTARY_STATUS:-Accepted}" ;;
            id) printf '11111111-2222-3333-4444-555555555555\n' ;;
            *) exit 1 ;;
        esac
        ;;
    security)
        printf '  1) ABCDEF1234567890 "%s"\n' "$MOCK_SIGNING_IDENTITY"
        printf '     1 valid identities found\n'
        ;;
    spctl)
        printf 'spctl\t%s\n' "$*" >>"$MOCK_LOG"
        ;;
    vtool)
        printf '      minos 12.0\n'
        printf '      minos 12.0\n'
        ;;
    xcrun)
        printf 'xcrun\t%s\n' "$*" >>"$MOCK_LOG"
        case " ${*} " in
            *' notarytool history '*)
                [ "${MOCK_PROFILE_INVALID:-0}" != '1' ] || exit 1
                printf '{"history":[]}\n'
                ;;
            *' notarytool submit '*)
                case " ${*} " in
                    *' --keychain-profile qlomni-notary '*) ;;
                    *) exit 1 ;;
                esac
                case " ${*} " in
                    *' --apple-id '*|*' --password '*) exit 1 ;;
                esac
                cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>status</key><string>Accepted</string>
<key>id</key><string>11111111-2222-3333-4444-555555555555</string>
</dict></plist>
PLIST
                ;;
            *' notarytool log '*)
                if [ "${MOCK_NOTARY_STATUS:-Accepted}" = 'Accepted' ]; then
                    printf '{"issues":[]}\n' >"$last_argument"
                else
                    printf '{"issues":[{"severity":"error"}]}\n' >"$last_argument"
                fi
                ;;
            *' stapler staple '*|*' stapler validate '*) ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF

chmod +x "$mock_tool"
for tool_name in codesign ditto lipo plutil security spctl vtool xcrun; do
    ln -s mock-tool "$mock_bin/$tool_name"
done

release_app="$test_directory/QLOmni.app"
mkdir -p \
    "$release_app/Contents/MacOS" \
    "$release_app/Contents/PlugIns/QLOmniExtension.appex/Contents/MacOS"
: >"$release_app/Contents/Info.plist"
: >"$release_app/Contents/MacOS/QLOmni"
: >"$release_app/Contents/PlugIns/QLOmniExtension.appex/Contents/Info.plist"
: >"$release_app/Contents/PlugIns/QLOmniExtension.appex/Contents/MacOS/QLOmniExtension"

signing_identity='Developer ID Application: Example'
release_zip="$test_directory/QLOmni-1.10.0.zip"

run_command env \
    MOCK_LOG="$mock_log" \
    MOCK_SIGNING_IDENTITY="$signing_identity" \
    PATH="$mock_bin:/usr/bin:/bin" \
    "$repository_root/scripts/package-release" \
    --app "$release_app" \
    --output "$release_zip" \
    --keychain-profile qlomni-notary \
    --signing-identity "$signing_identity" \
    --team-id EXAMPLETEAM \
    --expected-version 1.10.0
assert_status "$EXPECTED_SUCCESS"
assert_stdout_contains 'Accepted submission: 11111111-2222-3333-4444-555555555555'
[ -f "$release_zip" ] || fail 'release ZIP was not created'
[ -f "$release_zip.sha256" ] || fail 'release checksum was not created'

sign_count=$(grep -c '^sign' "$mock_log")
[ "$sign_count" -eq 2 ] || fail "expected two signing operations, got $sign_count"
first_signed=$(grep '^sign' "$mock_log" | sed -n '1p')
second_signed=$(grep '^sign' "$mock_log" | sed -n '2p')
case "$first_signed" in
    *'--options runtime'*'--timestamp'*'Support/QLOmniExtension.entitlements'*QLOmniExtension.appex) ;;
    *) fail 'extension was not signed first' ;;
esac
case "$second_signed" in
    *'--options runtime'*'--timestamp'*'Support/QLOmni.entitlements'*QLOmni.app) ;;
    *) fail 'host app was not signed second' ;;
esac

notary_submit=$(grep $'^xcrun\tnotarytool submit' "$mock_log")
case "$notary_submit" in
    *'--keychain-profile qlomni-notary'*'--wait'*'--timeout 30m'*'--output-format plist'*) ;;
    *) fail 'notary submission did not use the expected Keychain profile and wait settings' ;;
esac
case "$notary_submit" in
    *'--apple-id '*|*'--password '*) fail 'notary submission exposed ordinary credentials' ;;
esac
grep -Fq $'xcrun\tstapler staple' "$mock_log" || fail 'app was not stapled'
grep -Fq $'xcrun\tstapler validate' "$mock_log" || fail 'staple was not validated'
grep -Fq $'spctl\t--assess --type execute' "$mock_log" || fail 'final ZIP was not assessed by Gatekeeper'

adhoc_log="$test_directory/adhoc.log"
run_command env \
    MOCK_LOG="$adhoc_log" \
    MOCK_SIGNATURE_KIND=adhoc \
    PATH="$mock_bin:/usr/bin:/bin" \
    "$repository_root/scripts/verify-release" \
    --ad-hoc \
    --expected-version=1.10.0 \
    "$release_app"
assert_status "$EXPECTED_SUCCESS"
assert_stdout_contains 'Signing: ad-hoc'
[ ! -s "$adhoc_log" ] || fail 'ad-hoc verification invoked notarization or Gatekeeper tools'

run_command env \
    MOCK_LOG="$mock_log" \
    MOCK_SIGNATURE_KIND=adhoc \
    MOCK_VERSION=1.10.0 \
    PATH="$mock_bin:/usr/bin:/bin" \
    "$repository_root/scripts/verify-release" \
    --ad-hoc \
    --expected-version=2.0.0 \
    "$release_app"
assert_status 1
assert_stderr_contains 'app version is 1.10.0, expected 2.0.0'

invalid_profile_zip="$test_directory/QLOmni-invalid-profile.zip"
run_command env \
    MOCK_LOG="$mock_log" \
    MOCK_PROFILE_INVALID=1 \
    MOCK_SIGNING_IDENTITY="$signing_identity" \
    PATH="$mock_bin:/usr/bin:/bin" \
    "$repository_root/scripts/package-release" \
    --app "$release_app" \
    --output "$invalid_profile_zip" \
    --keychain-profile qlomni-notary \
    --signing-identity "$signing_identity" \
    --team-id EXAMPLETEAM \
    --expected-version 1.10.0
assert_status 1
assert_stderr_contains 'Keychain profile is unavailable or invalid'
[ ! -e "$invalid_profile_zip" ] || fail 'invalid-profile ZIP was not removed'

rejected_zip="$test_directory/QLOmni-rejected.zip"
run_command env \
    MOCK_LOG="$mock_log" \
    MOCK_NOTARY_STATUS=Invalid \
    MOCK_SIGNING_IDENTITY="$signing_identity" \
    PATH="$mock_bin:/usr/bin:/bin" \
    "$repository_root/scripts/package-release" \
    --app "$release_app" \
    --output "$rejected_zip" \
    --keychain-profile qlomni-notary \
    --signing-identity "$signing_identity" \
    --team-id EXAMPLETEAM \
    --expected-version 1.10.0
assert_status 1
assert_stderr_contains 'finished with status Invalid'
assert_stderr_contains 'Apple notary log'
[ ! -e "$rejected_zip" ] || fail 'rejected ZIP was not removed'
[ ! -e "$rejected_zip.sha256" ] || fail 'rejected checksum was not removed'

run_command env \
    MOCK_LOG="$mock_log" \
    MOCK_SIGNING_IDENTITY="$signing_identity" \
    PATH="$mock_bin:/usr/bin:/bin" \
    "$repository_root/scripts/package-release" \
    --app "$release_app" \
    --output "$release_zip" \
    --keychain-profile qlomni-notary \
    --signing-identity "$signing_identity" \
    --team-id EXAMPLETEAM \
    --expected-version 1.10.0
assert_status "$EXPECTED_USAGE"
assert_stderr_contains 'output already exists'

if rg -n 'APPLE_|--apple-id|--password' "$repository_root/scripts/package-release" "$repository_root/scripts/release" >/dev/null; then
    fail 'release scripts contain forbidden ordinary Apple credential plumbing'
fi

printf 'Release command-line tests passed\n'
