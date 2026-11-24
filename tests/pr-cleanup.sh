#!/bin/sh
set -eu
src=$(dirname "$0")/..
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-pr-cleanup.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
tmp=$(cd "$tmp" && pwd -P)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
source=$tmp/source
data=$tmp/data
task=$data/task-sessions-v2/task.fixture
store=$task/store.git
wt=$task/worktree
branch=ternmate/pr-7-fixture
mkdir -p "$source" "$task/session"
git -C "$source" init -q --template=
printf '%s\n' baseline > "$source/tracked"
printf '%s\n' '*.ignored' > "$source/.gitignore"
git -C "$source" add tracked .gitignore
git -C "$source" -c user.name=Fixture -c user.email=fixture@example.test commit -qm baseline
head=$(git -C "$source" rev-parse HEAD)
git init -q --bare --template= "$store"
cp "$store/config" "$task/initial-git-config"
git --git-dir="$store" fetch -q "$source" HEAD
git --git-dir="$store" update-ref refs/ternmate/initial "$head"
git --git-dir="$store" worktree add -q -b "$branch" -- "$wt" "$head"
printf '%s\n' 'saved conversation' > "$task/session/fixture.jsonl"
printf '%s\n' 'saved evidence' > "$task/materials.md"
probe() {
    expected=$1
    shift
    code=0
    /bin/sh "$src/session-setup.sh" "$@" || code=$?
    [ "$code" -eq "$expected" ] || { printf '%s\n' "Expected $expected, received $code ($1)" >&2; exit 1; }
}
probe 0 cleanup-pr-check "$data" "$task" "$head" 7
[ -d "$wt" ] && [ ! -e "$task/worktree-cleaned" ]
printf '%s\n' unstaged >> "$wt/tracked"
probe 2 cleanup-pr "$data" "$task" "$head" 7
[ "$(tail -n 1 "$wt/tracked")" = unstaged ]
git -C "$wt" restore tracked
printf '%s\n' untracked > "$wt/untracked"
probe 2 cleanup-pr "$data" "$task" "$head" 7
[ -e "$wt/untracked" ]; rm "$wt/untracked"
printf '%s\n' ignored > "$wt/output.ignored"
probe 2 cleanup-pr "$data" "$task" "$head" 7
[ -e "$wt/output.ignored" ]; rm "$wt/output.ignored"
git -C "$wt" update-index --assume-unchanged tracked
probe 5 cleanup-pr "$data" "$task" "$head" 7
git -C "$wt" update-index --no-assume-unchanged tracked
git --git-dir="$store" worktree lock "$wt"
probe 5 cleanup-pr "$data" "$task" "$head" 7
git --git-dir="$store" worktree unlock "$wt"
git -C "$wt" -c user.name=Fixture -c user.email=fixture@example.test commit --allow-empty -qm local
local_head=$(git -C "$wt" rev-parse HEAD)
probe 3 cleanup-pr "$data" "$task" "$head" 7
[ "$(git -C "$wt" rev-parse HEAD)" = "$local_head" ]
git -C "$wt" reset --hard -q "$head"
scope=6769746875622e74657374-72-76
other_scope=6769746875622e74657374-72-77
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope")" = end ]
(TERNMATE_CLEANUP_HISTORY=$scope TERNMATE_CLEANUP_MODE=review probe 0 cleanup-pr "$data" "$task" "$head" 7)
history=$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope")
[ "$(printf '%s\n' "$history" | cut -f2-)" = "$(printf 'review\t7\t%s\t%s\nend' "$branch" "$head")" ]
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$other_scope")" = end ]
[ ! -e "$wt" ]
! git --git-dir="$store" show-ref --verify --quiet "refs/heads/$branch"
[ "$(git -C "$source" rev-parse HEAD)" = "$head" ]
[ "$(cat "$task/session/fixture.jsonl")" = 'saved conversation' ]
[ "$(cat "$task/materials.md")" = 'saved evidence' ]
probe 8 cleanup-pr-check "$data" "$task" "$head" 7
probe 6 check "$task" "$head"
probe 0 restore-pr "$task" "$head" 7
[ "$(git -C "$wt" rev-parse HEAD)" = "$head" ]
[ "$(git -C "$wt" branch --show-current)" = "$branch" ]
[ ! -e "$task/worktree-cleaned" ]
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope")" = "$history" ]

ref=refs/heads/$branch
marker=$task/worktree-cleaned
interrupt_branch_delete() {
    # Permit worktree removal but stop Git at the branch deletion.
    touch "$store/$ref.lock"
    (TERNMATE_CLEANUP_HISTORY=$scope probe 9 cleanup-pr "$data" "$task" "$head" 7)
    rm -- "$store/$ref.lock"
    [ ! -e "$wt" ] && [ -f "$marker" ]
    [ "$(git --git-dir="$store" rev-parse "$ref")" = "$head" ]
}

interrupt_branch_delete
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope")" = "$history" ]
probe 0 restore-pr "$task" "$head" 7
probe 0 cleanup-pr "$data" "$task" "$head" 7
# An incomplete automatic attempt must not become history after restoring and
# then manually cleaning the same branch.
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope")" = "$history" ]
probe 0 restore-pr "$task" "$head" 7

interrupt_branch_delete
# Model interruption immediately after the successful branch deletion.
git --git-dir="$store" update-ref -d "$ref" "$head"
probe 8 cleanup-pr-check "$data" "$task" "$head" 7
pending=$(cat "$marker")
{
    IFS= read -r saved
    IFS=' ' read -r pending_scope at receipt pending_kind pending_number
} < "$marker"
[ "$pending_scope" = "$scope" ] && [ "$pending_kind" = pr ] && [ "$pending_number" = 7 ]
blocked=$data/auto-cleanup-history-v1/$scope/$at.fixture.$receipt.event
mkdir "$blocked"
probe 1 cleanup-history "$data" "$scope"
probe 1 restore-pr "$task" "$head" 7
[ "$(cat "$marker")" = "$pending" ] && [ ! -e "$wt" ]
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$other_scope")" = end ]
rmdir "$blocked"
recovered=$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope")
[ "$(printf '%s\n' "$recovered" | grep -Fxc "$(printf '%s\tpr\t7\t%s\t%s' "$at" "$branch" "$head")")" -eq 1 ]
[ "$(printf '%s\n' "$recovered" | wc -l)" -eq 3 ]
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope")" = "$recovered" ]
probe 0 restore-pr "$task" "$head" 7
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope")" = "$recovered" ]

interrupt_branch_delete
git --git-dir="$store" update-ref -d "$ref" "$head"
# Restoring before anyone opens history must preserve the completed cleanup.
probe 0 restore-pr "$task" "$head" 7
[ "$(/bin/sh "$src/session-setup.sh" cleanup-history "$data" "$scope" | wc -l)" -eq 4 ]
[ "$(git -C "$wt" rev-parse HEAD)" = "$head" ]
[ "$(git -C "$source" rev-parse HEAD)" = "$head" ]
printf '%s\n' 'PR cleanup protects local work, restores the exact workspace, and recovers history without duplicate events.'
