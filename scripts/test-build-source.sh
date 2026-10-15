#!/bin/sh
# Exercise source-policy behavior using only synthetic repositories, never a copy
# or worktree of the application checkout. No Xcode installation is needed.
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
task_temp=$(mktemp -d "${TMPDIR:-/tmp}/stories-source-tests.XXXXXX")
trap 'rm -rf "$task_temp"' EXIT HUP INT TERM
task_passed=0

# Do not let the developer's Git configuration influence these fixtures.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0
export GIT_AUTHOR_NAME='Stories fixture' GIT_AUTHOR_EMAIL='fixture@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

make_fixture() {
    mkdir -p "$1/scripts"
    cp "$task_root/scripts/check-main.sh" "$1/scripts/check-main.sh"
}

expect_pass() {
    if task_output=$(/bin/sh "$2/scripts/check-main.sh" 2>&1); then
        case "$task_output" in
            *"$3"*) ;;
            *) printf 'FAIL: %s (missing expected diagnostic: %s)\n%s\n' "$1" "$3" "$task_output" >&2; exit 1 ;;
        esac
    else
        printf 'FAIL: %s\n%s\n' "$1" "$task_output" >&2
        exit 1
    fi
    task_passed=$((task_passed + 1))
    printf 'PASS: %s\n' "$1"
}

expect_failure() {
    if task_output=$(/bin/sh "$2/scripts/check-main.sh" 2>&1); then
        printf 'FAIL: %s (unexpected success)\n%s\n' "$1" "$task_output" >&2
        exit 1
    fi
    case "$task_output" in
        *"$3"*) ;;
        *) printf 'FAIL: %s (missing expected error: %s)\n%s\n' "$1" "$3" "$task_output" >&2; exit 1 ;;
    esac
    task_passed=$((task_passed + 1))
    printf 'PASS: %s\n' "$1"
}

task_repo="$task_temp/source with spaces"
make_fixture "$task_repo"
expect_pass 'source archive and path with spaces' "$task_repo" 'source archive'
git init --quiet -b main "$task_repo"
expect_pass 'repository without commits' "$task_repo" 'no commits'
git -C "$task_repo" add scripts/check-main.sh
git -C "$task_repo" commit --quiet -m 'Synthetic fixture'
expect_pass 'ordinary main checkout' "$task_repo" '| main |'
expect_pass 'clean revision diagnostic' "$task_repo" '| clean'
printf '\n# synthetic local change\n' >> "$task_repo/scripts/check-main.sh"
expect_pass 'uncommitted local edits' "$task_repo" 'with local changes'
git -C "$task_repo" checkout --quiet -b contribution
expect_pass 'contributor branch' "$task_repo" '| contribution |'
git -C "$task_repo" checkout --quiet --detach HEAD
expect_pass 'detached CI checkout' "$task_repo" '| detached HEAD |'
git -C "$task_repo" config --local stories.requirePrimaryMain true
expect_failure 'strict mode rejects detached HEAD' "$task_repo" 'stories.requirePrimaryMain is enabled'
git -C "$task_repo" checkout --quiet contribution
expect_failure 'strict mode rejects another branch' "$task_repo" 'stories.requirePrimaryMain is enabled'
git -C "$task_repo" checkout --quiet main
expect_pass 'strict mode accepts primary main with local edits' "$task_repo" '| main |'
git -C "$task_repo" config --local stories.requirePrimaryMain invalid
expect_failure 'invalid strict-mode configuration fails clearly' "$task_repo" 'valid Git boolean'
git -C "$task_repo" config --local stories.requirePrimaryMain false
git -C "$task_repo" checkout --quiet --detach HEAD
expect_pass 'explicit false permits detached HEAD' "$task_repo" '| detached HEAD |'

task_nested="$task_repo/extracted archive"
make_fixture "$task_nested"
git -C "$task_repo" config --local stories.requirePrimaryMain true
expect_pass 'archive ignores parent repository policy' "$task_nested" 'source archive'

task_separate="$task_temp/separate metadata"
make_fixture "$task_separate"
git init --quiet -b main --separate-git-dir="$task_temp/fixture.git" "$task_separate"
expect_pass 'Git file works by default' "$task_separate" '| main |'
git -C "$task_separate" config --local stories.requirePrimaryMain true
expect_failure 'strict mode rejects Git file checkouts' "$task_separate" 'stories.requirePrimaryMain is enabled'

task_broken="$task_temp/broken metadata"
make_fixture "$task_broken"
printf 'gitdir: missing-repository\n' > "$task_broken/.git"
expect_failure 'broken Git metadata fails clearly' "$task_broken" 'repository cannot be read'
printf '%s source-policy checks passed.\n' "$task_passed"
