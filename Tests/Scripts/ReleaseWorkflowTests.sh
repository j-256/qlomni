#!/bin/bash

set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/../.." && pwd)
workflow_path="$repository_root/.github/workflows/ci.yml"
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/qlomni-workflow-tests.XXXXXX")
test_directory=$(CDPATH='' cd -- "$test_directory" && pwd)
stdout_path="$test_directory/stdout"
stderr_path="$test_directory/stderr"
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM

last_status=0

fail() {
    printf 'ReleaseWorkflowTests: %s\n' "$1" >&2
    printf '%s\n' '--- stdout ---' >&2
    sed 's/^/  /' "$stdout_path" >&2
    printf '%s\n' '--- stderr ---' >&2
    sed 's/^/  /' "$stderr_path" >&2
    exit 1
}

assert_log_absent() {
    if grep -Fq -- "$1" "$MOCK_LOG"; then
        fail "unexpected log entry: $1"
    fi
}

event_line() {
    local pattern

    pattern=$1
    grep -nF -- "$pattern" "$MOCK_LOG" | head -n 1 | cut -d: -f1
}

assert_before() {
    local first_line
    local second_line

    first_line=$(event_line "$1") || fail "missing log entry: $1"
    second_line=$(event_line "$2") || fail "missing log entry: $2"
    [ "$first_line" -lt "$second_line" ] || fail "expected '$1' before '$2'"
}

run_release() {
    local fixture_root
    local release_mode

    fixture_root=$1
    release_mode=${2:-}
    shift 2

    set +e
    if [ -n "$release_mode" ]; then
        env \
            MOCK_BREW_REPOSITORY="$fixture_root/brew-repository" \
            MOCK_GH_STATE="$fixture_root/gh-release-created" \
            MOCK_LOG="$fixture_root/events.log" \
            MOCK_TAP_DIRECTORY="$fixture_root/homebrew-tap" \
            MOCK_TAP_REMOTE='git@github.com:j-256/homebrew-tap.git' \
            PATH="$fixture_root/bin:/usr/bin:/bin" \
            "$@" \
            "$fixture_root/repo/scripts/release" \
            "$release_mode" \
            --version 1.11.0 \
            --keychain-profile qlomni-notary \
            --signing-identity 'Developer ID Application: Example' \
            --team-id EXAMPLETEAM \
            >"$stdout_path" 2>"$stderr_path"
    else
        env \
            MOCK_BREW_REPOSITORY="$fixture_root/brew-repository" \
            MOCK_GH_STATE="$fixture_root/gh-release-created" \
            MOCK_LOG="$fixture_root/events.log" \
            MOCK_TAP_DIRECTORY="$fixture_root/homebrew-tap" \
            MOCK_TAP_REMOTE='git@github.com:j-256/homebrew-tap.git' \
            PATH="$fixture_root/bin:/usr/bin:/bin" \
            "$@" \
            "$fixture_root/repo/scripts/release" \
            --version 1.11.0 \
            --keychain-profile qlomni-notary \
            --signing-identity 'Developer ID Application: Example' \
            --team-id EXAMPLETEAM \
            >"$stdout_path" 2>"$stderr_path"
    fi
    last_status=$?
    set -e
}

create_fixture() {
    local fixture_root
    local brew_repository
    local repository
    local remote
    local fake_bin
    local tap_remote
    local tap_repository

    fixture_root=$1
    brew_repository="$fixture_root/brew-repository"
    repository="$fixture_root/repo"
    remote="$fixture_root/origin.git"
    fake_bin="$fixture_root/bin"
    tap_remote="$fixture_root/j-256/homebrew-tap.git"
    tap_repository="$fixture_root/homebrew-tap"

    mkdir -p \
        "$repository/scripts" \
        "$repository/tools" \
        "$repository/QLOmni.xcodeproj" \
        "$tap_repository/Casks" \
        "${tap_remote%/*}" \
        "$brew_repository/Library/Taps" \
        "$fake_bin"
    : >"$fixture_root/events.log"
    /usr/bin/git init --bare --quiet "$remote"
    /usr/bin/git init --bare --quiet "$tap_remote"
    /usr/bin/git init --quiet -b main "$repository"
    /usr/bin/git init --quiet -b main "$tap_repository"

    printf 'build/\n' >"$repository/.gitignore"
    printf 'MARKETING_VERSION = 1.10.0;\n' >"$repository/QLOmni.xcodeproj/project.pbxproj"
    printf 'QLOmniExtension(1.10.0)\n' >"$repository/README.md"
    cp "$repository_root/scripts/release" "$repository/scripts/release"

    cat >"$tap_repository/Casks/qlomni.rb" <<'EOF'
cask "qlomni" do
  version "1.10.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/j-256/qlomni/releases/download/v#{version}/QLOmni-#{version}.zip"
  name "QLOmni"
  desc "Preview text files that macOS Quick Look does not recognize"
  homepage "https://github.com/j-256/qlomni"

  depends_on macos: :monterey

  app "QLOmni.app"
end
EOF

    cat >"$repository/tools/check-release-integration.sh" <<'EOF'
#!/bin/bash

set -eu

printf 'integration-decision\n' >>"$MOCK_LOG"
exit "${MOCK_INTEGRATION_STATUS:-1}"
EOF

    cat >"$repository/scripts/package-release" <<'EOF'
#!/bin/bash

set -eu

output=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done

printf 'package:notarize\n' >>"$MOCK_LOG"
mkdir -p "${output%/*}"
printf 'partial artifact\n' >"$output"
printf 'partial checksum\n' >"$output.sha256"
if [ "${MOCK_PACKAGE_FAIL:-0}" = '1' ]; then
    printf 'mock notarization rejected\n' >&2
    exit 1
fi
printf 'signed notarized artifact\n' >"$output"
(
    cd "${output%/*}"
    shasum -a 256 "${output##*/}" >"${output##*/}.sha256"
)
EOF

    cat >"$repository/scripts/verify-release" <<'EOF'
#!/bin/bash

set -eu

last_argument=${!#}
printf 'verify:%s\n' "$last_argument" >>"$MOCK_LOG"
[ "${MOCK_VERIFY_FAIL:-0}" != '1' ] || exit 1
[ -f "$last_argument" ]
EOF

    cat >"$fake_bin/make" <<'EOF'
#!/bin/bash

set -eu

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-print-directory) shift ;;
        *) break ;;
    esac
done

target=${1:-}
printf 'make:%s\n' "$*" >>"$MOCK_LOG"
case "$target" in
    test) ;;
    release-integration) ;;
    version)
        version=${2#V=}
        /usr/bin/sed -i '' -E "s/[0-9]+\.[0-9]+\.[0-9]+/$version/g" QLOmni.xcodeproj/project.pbxproj README.md
        ;;
    build)
        mkdir -p build/Build/Products/Release/QLOmni.app
        ;;
    print-version)
        /usr/bin/awk -F'[ =;]+' '/MARKETING_VERSION/ { print $2; exit }' QLOmni.xcodeproj/project.pbxproj
        ;;
    print-uti-surface)
        printf '%s\n' 'QLOmni/QLOmni/Info.plist QLOmniExtension/Info.plist integration/'
        ;;
    *) printf 'unexpected make target: %s\n' "$target" >&2; exit 1 ;;
esac
EOF

    cat >"$fake_bin/brew" <<'EOF'
#!/bin/bash

set -eu

printf 'brew:%s\n' "$*" >>"$MOCK_LOG"
case "${1:-}" in
    --repository)
        printf '%s\n' "$MOCK_BREW_REPOSITORY"
        ;;
    audit)
        audit_link="$MOCK_BREW_REPOSITORY/Library/Taps/qlomni-release/homebrew-tap"
        [ -L "$audit_link" ] || exit 1
        [ "$(readlink "$audit_link")" = "$MOCK_TAP_DIRECTORY" ] || exit 1
        [ "${MOCK_BREW_AUDIT_FAIL:-0}" != '1' ] || exit 1
        ;;
    *)
        printf 'unexpected brew invocation: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF

    cat >"$fake_bin/git" <<'EOF'
#!/bin/bash

set -eu

if [ "${1:-}" = '-C' ] && [ "${2:-}" = "$MOCK_TAP_DIRECTORY" ]; then
    shift 2
    printf 'tap:%s\n' "$*" >>"$MOCK_LOG"
    if [ "$1" = 'remote' ] && [ "$2" = 'get-url' ] && [ "$3" = 'origin' ]; then
        printf '%s\n' "$MOCK_TAP_REMOTE"
        exit 0
    fi
    if [ "${1:-}" = 'push' ] && [ "${MOCK_TAP_PUSH_FAIL:-0}" = '1' ]; then
        printf 'mock tap push failure\n' >&2
        exit 1
    fi
    exec /usr/bin/git -C "$MOCK_TAP_DIRECTORY" "$@"
fi

printf 'git:%s\n' "$*" >>"$MOCK_LOG"
if [ "${1:-}" = 'push' ] && [ "${MOCK_PUSH_FAIL:-0}" = '1' ]; then
    printf 'mock push failure\n' >&2
    exit 1
fi
exec /usr/bin/git "$@"
EOF

    cat >"$fake_bin/gh" <<'EOF'
#!/bin/bash

set -eu

printf 'gh:%s\n' "$*" >>"$MOCK_LOG"
case " $* " in
    *' auth status '*) ;;
    *' repo view '*) printf '{"nameWithOwner":"example/qlomni"}\n' ;;
    *' release view '*)
        [ -e "$MOCK_GH_STATE" ] || exit 1
        ;;
    *' release create '*)
        [ "${MOCK_GH_CREATE_FAIL:-0}" != '1' ] || exit 1
        : >"$MOCK_GH_STATE"
        ;;
    *' release upload '*) ;;
    *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

    chmod +x \
        "$repository/scripts/release" \
        "$repository/scripts/package-release" \
        "$repository/scripts/verify-release" \
        "$repository/tools/check-release-integration.sh" \
        "$fake_bin/brew" \
        "$fake_bin/make" \
        "$fake_bin/git" \
        "$fake_bin/gh"

    (
        cd "$repository"
        /usr/bin/git config user.name 'Release Test'
        /usr/bin/git config user.email 'release@example.test'
        /usr/bin/git add .gitignore QLOmni.xcodeproj/project.pbxproj README.md scripts/package-release scripts/release scripts/verify-release tools/check-release-integration.sh
        /usr/bin/git commit --quiet -m 'Initial fixture'
        /usr/bin/git remote add origin "$remote"
        /usr/bin/git push --quiet -u origin main
    )
    (
        cd "$tap_repository"
        /usr/bin/git config user.name 'Release Test'
        /usr/bin/git config user.email 'release@example.test'
        /usr/bin/git add Casks/qlomni.rb
        /usr/bin/git commit --quiet -m 'Initial tap fixture'
        /usr/bin/git remote add origin "$tap_remote"
        /usr/bin/git push --quiet -u origin main
    )
}

for forbidden_pattern in \
    'secrets.' \
    'vars.' \
    'environment:' \
    'APPLE_' \
    'MACOS_CERTIFICATE' \
    'SIGNING_IDENTITY' \
    'notarytool' \
    'Developer ID' \
    'gh release' \
    'contents: write'; do
    if grep -Fq -- "$forbidden_pattern" "$workflow_path"; then
        fail "CI contains forbidden release credential or publication pattern: $forbidden_pattern"
    fi
done
grep -Fq 'contents: read' "$workflow_path" || fail 'CI does not declare read-only contents permission'
grep -Fq -- '--ad-hoc' "$workflow_path" || fail 'CI does not verify ad-hoc signatures'
grep -Fq 'qlomni-adhoc-dry-run' "$workflow_path" || fail 'CI artifact is not clearly labeled as an ad-hoc dry run'

dirty_fixture="$test_directory/dirty"
create_fixture "$dirty_fixture"
printf 'untracked\n' >"$dirty_fixture/repo/untracked"
MOCK_LOG="$dirty_fixture/events.log"
run_release "$dirty_fixture" ''
[ "$last_status" -ne 0 ] || fail 'dirty-tree guard unexpectedly succeeded'
grep -Fq 'working tree must be clean' "$stderr_path" || fail 'dirty-tree guard did not explain the failure'
assert_log_absent 'make:test'
assert_log_absent 'git:push'
assert_log_absent 'gh:release create'

tap_dirty_fixture="$test_directory/tap-dirty"
create_fixture "$tap_dirty_fixture"
printf 'untracked\n' >"$tap_dirty_fixture/homebrew-tap/untracked"
MOCK_LOG="$tap_dirty_fixture/events.log"
run_release "$tap_dirty_fixture" ''
[ "$last_status" -ne 0 ] || fail 'dirty Homebrew tap guard unexpectedly succeeded'
grep -Fq 'Homebrew tap has unrelated changes' "$stderr_path" || fail 'dirty Homebrew tap guard did not explain the failure'
assert_log_absent 'make:test'
assert_log_absent 'package:notarize'
assert_log_absent 'git:push'
assert_log_absent 'gh:release create'
assert_log_absent 'brew:audit'

tap_remote_fixture="$test_directory/tap-remote"
create_fixture "$tap_remote_fixture"
MOCK_LOG="$tap_remote_fixture/events.log"
run_release "$tap_remote_fixture" '' MOCK_TAP_REMOTE=git@github.com:someone-else/homebrew-tap.git
[ "$last_status" -ne 0 ] || fail 'incorrect Homebrew tap origin unexpectedly passed the guard'
grep -Fq 'expected j-256/homebrew-tap' "$stderr_path" || fail 'incorrect Homebrew tap origin was not explained'
assert_log_absent 'make:test'
assert_log_absent 'package:notarize'
assert_log_absent 'git:push'
assert_log_absent 'gh:release create'

integration_decision_fixture="$test_directory/integration-decision-failure"
create_fixture "$integration_decision_fixture"
MOCK_LOG="$integration_decision_fixture/events.log"
run_release "$integration_decision_fixture" '--dry-run' MOCK_INTEGRATION_STATUS=2
[ "$last_status" -ne 0 ] || fail 'integration decision failure unexpectedly succeeded'
grep -Fq 'integration-test decision failed with status 2' "$stderr_path" || fail 'integration decision failure was not surfaced'
assert_log_absent 'package:notarize'
assert_log_absent 'git:commit'
assert_log_absent 'git:push'
assert_log_absent 'gh:release create'
assert_log_absent 'tap:'
assert_log_absent 'brew:'

integration_run_fixture="$test_directory/integration-run"
create_fixture "$integration_run_fixture"
MOCK_LOG="$integration_run_fixture/events.log"
run_release "$integration_run_fixture" '--dry-run' MOCK_INTEGRATION_STATUS=0
[ "$last_status" -eq 0 ] || fail 'forced integration dry run unexpectedly failed'
assert_before 'integration-decision' 'make:release-integration'
assert_before 'make:release-integration' 'package:notarize'
assert_log_absent 'git:commit'
assert_log_absent 'git:push'
assert_log_absent 'gh:release create'
assert_log_absent 'tap:'
assert_log_absent 'brew:'

notary_fixture="$test_directory/notary-failure"
create_fixture "$notary_fixture"
MOCK_LOG="$notary_fixture/events.log"
run_release "$notary_fixture" '' MOCK_PACKAGE_FAIL=1
[ "$last_status" -ne 0 ] || fail 'notarization failure unexpectedly succeeded'
grep -Fq 'mock notarization rejected' "$stderr_path" || fail 'notarization failure was not surfaced'
grep -Fq 'Release failed before its commit' "$stderr_path" || fail 'pre-commit recovery guidance was not printed'
[ ! -e "$notary_fixture/repo/build/releases/QLOmni-1.11.0.zip" ] || fail 'failed release artifact was not cleaned up'
[ -z "$(/usr/bin/git -C "$notary_fixture/repo" status --porcelain)" ] || fail 'version changes were not restored after notarization failure'
[ "$(/usr/bin/git -C "$notary_fixture/repo" log -1 --format=%s)" = 'Initial fixture' ] || fail 'release commit was created before notarization passed'
assert_log_absent 'git:push'
assert_log_absent 'gh:release create'

verify_fixture="$test_directory/verification-failure"
create_fixture "$verify_fixture"
MOCK_LOG="$verify_fixture/events.log"
run_release "$verify_fixture" '' MOCK_VERIFY_FAIL=1
[ "$last_status" -ne 0 ] || fail 'verification failure unexpectedly succeeded'
[ -z "$(/usr/bin/git -C "$verify_fixture/repo" status --porcelain)" ] || fail 'version changes were not restored after verification failure'
assert_log_absent 'git:commit'
assert_log_absent 'git:push'
assert_log_absent 'gh:release create'

dry_run_fixture="$test_directory/dry-run-verification-failure"
create_fixture "$dry_run_fixture"
MOCK_LOG="$dry_run_fixture/events.log"
run_release "$dry_run_fixture" '--dry-run' MOCK_VERIFY_FAIL=1
[ "$last_status" -ne 0 ] || fail 'dry-run verification failure unexpectedly succeeded'
[ ! -e "$dry_run_fixture/repo/build/releases/dry-run/QLOmni-1.11.0.zip" ] || fail 'failed dry-run artifact was not cleaned up'
assert_log_absent 'git:commit'
assert_log_absent 'git:tag -a'
assert_log_absent 'git:push'
assert_log_absent 'gh:release create'
assert_log_absent 'tap:'
assert_log_absent 'brew:'

success_fixture="$test_directory/success"
create_fixture "$success_fixture"
MOCK_LOG="$success_fixture/events.log"
run_release "$success_fixture" ''
[ "$last_status" -eq 0 ] || fail 'guarded release unexpectedly failed'
assert_before 'make:test' 'integration-decision'
assert_before 'integration-decision' 'package:notarize'
assert_log_absent 'make:release-integration'
assert_before 'package:notarize' 'git:commit'
assert_before 'verify:' 'git:commit'
assert_before 'git:commit' 'git:tag -a v1.11.0'
assert_before 'git:tag -a v1.11.0' 'git:push --atomic'
assert_before 'git:push --atomic' 'gh:release create'
assert_before 'gh:release create' 'brew:audit --cask --strict --online qlomni-release/tap/qlomni'
assert_before 'brew:audit --cask --strict --online qlomni-release/tap/qlomni' 'tap:commit -m chore(qlomni): update to 1.11.0'
assert_before 'tap:commit -m chore(qlomni): update to 1.11.0' 'tap:push origin HEAD:refs/heads/main'
verify_count=$(grep -c '^verify:' "$MOCK_LOG")
[ "$verify_count" -ge 5 ] || fail 'artifact was not reverified at each publication boundary'
remote_tag=$(/usr/bin/git --git-dir="$success_fixture/origin.git" rev-list -n 1 v1.11.0)
remote_main=$(/usr/bin/git --git-dir="$success_fixture/origin.git" rev-parse main)
[ "$remote_tag" = "$remote_main" ] || fail 'remote tag and main were not published together'
tap_remote="$success_fixture/j-256/homebrew-tap.git"
tap_cask=$(/usr/bin/git --git-dir="$tap_remote" show main:Casks/qlomni.rb)
printf '%s\n' "$tap_cask" | grep -Fq 'version "1.11.0"' || fail 'published cask version does not match the app release'
release_checksum=$(shasum -a 256 "$success_fixture/repo/build/releases/QLOmni-1.11.0.zip" | awk '{ print $1 }')
printf '%s\n' "$tap_cask" | grep -Fq "sha256 \"$release_checksum\"" || fail 'published cask checksum does not match the app artifact'
tap_subject=$(/usr/bin/git --git-dir="$tap_remote" log -1 --format=%s)
[ "$tap_subject" = 'chore(qlomni): update to 1.11.0' ] || fail 'Homebrew tap commit subject is incorrect'
[ ! -e "$success_fixture/brew-repository/Library/Taps/qlomni-release" ] || fail 'temporary Homebrew audit tap was not cleaned up'

resume_fixture="$test_directory/resume"
create_fixture "$resume_fixture"
MOCK_LOG="$resume_fixture/events.log"
run_release "$resume_fixture" '' MOCK_PUSH_FAIL=1
[ "$last_status" -ne 0 ] || fail 'mock push failure unexpectedly succeeded'
grep -Fq 'make release-resume V=1.11.0' "$stderr_path" || fail 'resume guidance was not printed after the local tag'
[ -e "$resume_fixture/repo/build/releases/QLOmni-1.11.0.zip" ] || fail 'verified artifact was not preserved for resume'
/usr/bin/git -C "$resume_fixture/repo" rev-parse --verify refs/tags/v1.11.0 >/dev/null || fail 'local tag was not preserved for resume'
: >"$MOCK_LOG"
run_release "$resume_fixture" '--resume'
[ "$last_status" -eq 0 ] || fail 'release resume unexpectedly failed'
assert_before 'verify:' 'git:push --atomic'
assert_before 'git:push --atomic' 'gh:release create'
if grep -Fq 'make:version' "$MOCK_LOG"; then
    fail 'resume repeated the version mutation'
fi

release_failure_fixture="$test_directory/release-failure"
create_fixture "$release_failure_fixture"
MOCK_LOG="$release_failure_fixture/events.log"
run_release "$release_failure_fixture" '' MOCK_GH_CREATE_FAIL=1
[ "$last_status" -ne 0 ] || fail 'mock GitHub Release failure unexpectedly succeeded'
grep -Fq 'make release-resume V=1.11.0' "$stderr_path" || fail 'resume guidance was not printed after remote publication'
/usr/bin/git --git-dir="$release_failure_fixture/origin.git" rev-parse --verify refs/tags/v1.11.0 >/dev/null || fail 'remote tag was not preserved after the Release failure'
: >"$MOCK_LOG"
run_release "$release_failure_fixture" '--resume'
[ "$last_status" -eq 0 ] || fail 'resume after GitHub Release failure unexpectedly failed'
assert_before 'verify:' 'gh:release create'
assert_log_absent 'git:push'

tap_audit_fixture="$test_directory/tap-audit-failure"
create_fixture "$tap_audit_fixture"
MOCK_LOG="$tap_audit_fixture/events.log"
run_release "$tap_audit_fixture" '' MOCK_BREW_AUDIT_FAIL=1
[ "$last_status" -ne 0 ] || fail 'mock Homebrew audit failure unexpectedly succeeded'
grep -Fq 'make release-resume V=1.11.0' "$stderr_path" || fail 'resume guidance was not printed after the Homebrew audit failure'
assert_before 'gh:release create' 'brew:audit --cask --strict --online qlomni-release/tap/qlomni'
assert_log_absent 'tap:commit'
assert_log_absent 'tap:push'
[ ! -e "$tap_audit_fixture/brew-repository/Library/Taps/qlomni-release" ] || fail 'failed Homebrew audit left its temporary tap behind'
local_tap_cask=$(sed -n '1,$p' "$tap_audit_fixture/homebrew-tap/Casks/qlomni.rb")
printf '%s\n' "$local_tap_cask" | grep -Fq 'version "1.11.0"' || fail 'failed Homebrew audit did not preserve the cask update'
remote_tap_cask=$(/usr/bin/git --git-dir="$tap_audit_fixture/j-256/homebrew-tap.git" show main:Casks/qlomni.rb)
printf '%s\n' "$remote_tap_cask" | grep -Fq 'version "1.10.0"' || fail 'Homebrew cask reached the remote before its audit passed'
/usr/bin/sed -i '' \
    's/desc "Preview text files that macOS Quick Look does not recognize"/desc "Unexpected edit"/' \
    "$tap_audit_fixture/homebrew-tap/Casks/qlomni.rb"
: >"$MOCK_LOG"
run_release "$tap_audit_fixture" '--resume'
[ "$last_status" -ne 0 ] || fail 'resume accepted changes beyond the cask version and checksum'
grep -Fq 'contains changes beyond the release version and checksum' "$stderr_path" || fail 'unexpected cask edit was not explained'
grep -Fq 'make release-resume V=1.11.0' "$stderr_path" || fail 'resume guidance was not printed after rejecting the cask edit'
assert_log_absent 'brew:audit'
assert_log_absent 'tap:commit'
assert_log_absent 'tap:push'
/usr/bin/sed -i '' \
    's/desc "Unexpected edit"/desc "Preview text files that macOS Quick Look does not recognize"/' \
    "$tap_audit_fixture/homebrew-tap/Casks/qlomni.rb"
: >"$MOCK_LOG"
run_release "$tap_audit_fixture" '--resume'
[ "$last_status" -eq 0 ] || fail 'resume after Homebrew audit failure unexpectedly failed'
assert_before 'gh:release upload' 'brew:audit --cask --strict --online qlomni-release/tap/qlomni'
assert_before 'brew:audit --cask --strict --online qlomni-release/tap/qlomni' 'tap:commit -m chore(qlomni): update to 1.11.0'
assert_before 'tap:commit -m chore(qlomni): update to 1.11.0' 'tap:push origin HEAD:refs/heads/main'

tap_push_fixture="$test_directory/tap-push-failure"
create_fixture "$tap_push_fixture"
MOCK_LOG="$tap_push_fixture/events.log"
run_release "$tap_push_fixture" '' MOCK_TAP_PUSH_FAIL=1
[ "$last_status" -ne 0 ] || fail 'mock Homebrew tap push failure unexpectedly succeeded'
grep -Fq 'make release-resume V=1.11.0' "$stderr_path" || fail 'resume guidance was not printed after the Homebrew tap push failure'
tap_ahead_count=$(/usr/bin/git -C "$tap_push_fixture/homebrew-tap" rev-list --count origin/main..HEAD)
[ "$tap_ahead_count" -eq 1 ] || fail 'Homebrew tap commit was not preserved after its push failed'
remote_tap_cask=$(/usr/bin/git --git-dir="$tap_push_fixture/j-256/homebrew-tap.git" show main:Casks/qlomni.rb)
printf '%s\n' "$remote_tap_cask" | grep -Fq 'version "1.10.0"' || fail 'failed Homebrew tap push changed the remote cask'
: >"$MOCK_LOG"
run_release "$tap_push_fixture" '--resume'
[ "$last_status" -eq 0 ] || fail 'resume after Homebrew tap push failure unexpectedly failed'
assert_log_absent 'tap:commit'
assert_before 'brew:audit --cask --strict --online qlomni-release/tap/qlomni' 'tap:push origin HEAD:refs/heads/main'
remote_tap_cask=$(/usr/bin/git --git-dir="$tap_push_fixture/j-256/homebrew-tap.git" show main:Casks/qlomni.rb)
printf '%s\n' "$remote_tap_cask" | grep -Fq 'version "1.11.0"' || fail 'Homebrew cask was not published by release resume'

printf 'Release workflow tests passed\n'
