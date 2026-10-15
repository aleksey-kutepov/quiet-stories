#!/bin/sh
# Portable by default. The owner can opt in to the primary-main workflow with:
# git config --local stories.requirePrimaryMain true
set -eu
export GIT_OPTIONAL_LOCKS=0
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

# An extracted source archive may live inside an unrelated Git repository.
# Never inherit that parent's settings or report its revision as our own.
if [ ! -e "$task_root/.git" ]; then
    printf 'Stories source: %s | source archive (no Git metadata)\n' "$task_root"
    exit 0
fi

# Locate Git from this source directory even when invoked by another Git tool.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
if ! task_git_root=$(git -C "$task_root" rev-parse --show-toplevel 2>/dev/null); then
    echo 'error: Stories has a .git entry, but its repository cannot be read.' >&2
    exit 1
fi
task_git_root=$(CDPATH= cd -- "$task_git_root" && pwd -P)
if [ "$task_git_root" != "$task_root" ]; then
    echo 'error: Stories Git metadata points to a different source directory.' >&2
    exit 1
fi

task_strict=false
if task_config=$(git -C "$task_root" config --local --bool --get stories.requirePrimaryMain 2>/dev/null); then
    task_strict=$task_config
else
    task_config_status=$?
    if [ "$task_config_status" -ne 1 ]; then
        echo 'error: stories.requirePrimaryMain must be a valid Git boolean (true or false).' >&2
        exit 1
    fi
fi
task_branch=$(git -C "$task_root" symbolic-ref --quiet --short HEAD || true)
if [ "$task_strict" = true ] && { [ "$task_branch" != main ] || [ ! -d "$task_root/.git" ]; }; then
    echo 'error: stories.requirePrimaryMain is enabled. Build from the primary repository on main; linked worktrees and detached HEAD builds are disabled.' >&2
    exit 1
fi
task_revision=$(git -C "$task_root" rev-parse --short HEAD 2>/dev/null || printf 'no commits')
task_changes=$(git -C "$task_root" status --porcelain)
task_state=clean
if [ -n "$task_changes" ]; then
    task_state='with local changes'
fi
printf 'Stories source: %s | %s | %s | %s\n' "$task_root" "${task_branch:-detached HEAD}" "$task_revision" "$task_state"
