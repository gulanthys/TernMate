#!/bin/sh
# Exercise local Git only: sh tests/issue-splits.sh
set -eu
src=$(dirname "$0")/..
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-split-test.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
tmp=$(cd "$tmp" && pwd -P)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.test
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
export GIT_AUTHOR_DATE=2000-01-01T00:00:00Z
export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE

helper() { /bin/sh "$src/session-setup.sh" "$@"; }
reject() {
    expected=$1 message=$2
    shift 2
    code=0
    "$@" > "$tmp/stdout" 2> "$tmp/stderr" || code=$?
    if [ "$code" -ne "$expected" ] || [ -s "$tmp/stdout" ] || ! grep -Fqx "$message" "$tmp/stderr"; then
        printf 'Expected exit %s and diagnostic "%s", got exit %s (%s).\n' "$expected" "$message" "$code" "$*" >&2
        cat "$tmp/stdout" "$tmp/stderr" >&2
        exit 1
    fi
}

checkout=$tmp/checkout
data=$tmp/data
tasks=$data/task-sessions-v2
task=$tasks/task.issue1
wt=$task/worktree
fixes=$task/fixes
branch=ternmate/issue-7-issue1
mkdir -p "$checkout" "$task"
git -C "$checkout" init -q --template=
printf 'baseline\n' > "$checkout/tracked"
printf 'tracked filter=fixture\n' > "$checkout/.gitattributes"
git -C "$checkout" add tracked .gitattributes
git -C "$checkout" commit -qm baseline
base=$(git -C "$checkout" rev-parse HEAD)
blob=$(git -C "$checkout" rev-parse HEAD:tracked)
git -C "$checkout" tag -a -m fixture baseline-tag "$base"
tag=$(git -C "$checkout" rev-parse refs/tags/baseline-tag)
helper prepare-issue "$task" "$checkout" 7 "$base"

printf 'aggregate commit\n' > "$wt/aggregate"
git -C "$wt" add aggregate
git -C "$wt" commit -qm aggregate
aggregate=$(git -C "$wt" rev-parse HEAD)
printf 'staged change\n' >> "$wt/tracked"
git -C "$wt" add tracked
printf 'unstaged change\n' >> "$wt/tracked"
printf 'untracked aggregate note\n' > "$wt/notes"
printf 'original checkout remains dirty\n' >> "$checkout/tracked"
cp "$checkout/tracked" "$tmp/checkout-tracked"
cp "$wt/tracked" "$tmp/aggregate-tracked"
cp "$wt/notes" "$tmp/aggregate-notes"
index=$(git -C "$wt" rev-parse --git-path index)
cp "$index" "$tmp/aggregate-index"
git --no-optional-locks -C "$wt" status --porcelain=v1 > "$tmp/aggregate-status"

split_issue() { helper split-worktree "$task" "$checkout" issue 7 "$@"; }
cleanup_blocked='任务包含拆分 worktree 或不安全的 fixes 目录；未清理。'
invalid_task='无效的私有任务目录。'
invalid_slug='无效的拆分名称。'
unsafe_config='Git 配置包含 filter 或条件包含，或无法核对配置；未拆分。'
branch_mismatch='原始 worktree 不在此任务的分支上。'
git -C "$checkout" branch "$branch-collision" "$base"
git -C "$checkout" show-ref > "$tmp/refs-before"
git -C "$checkout" worktree list --porcelain > "$tmp/worktrees-before"

for slug in '' '../escape' ':ref' '_initial' '-initial' Uppercase 'spaces here' 'a.letter' \
    012345678901234567890123456789012345678901234567890; do
    reject 1 "$invalid_slug" split_issue "$slug" "$base"
done
for invalid in HEAD "${base%?}" "$base^"; do
    reject 1 'base 必须是完整的提交 SHA。' split_issue invalid "$invalid"
done
zero=$(printf '%s' "$base" | tr '0-9a-f' 0)
for not_commit in "$zero" "$blob" "$tag"; do
    reject 1 'base 不是 Git 存储中一个确切的现有提交。' split_issue invalid "$not_commit"
done
reject 1 "$branch_mismatch" helper split-worktree "$task" "$checkout" issue 8 wrong-number "$base"
reject 1 '拆分分支已存在。' split_issue collision "$base"
[ ! -e "$fixes" ]

ln -s "$task" "$tasks/task.link"
ln -s "$data" "$tmp/data-link"
for invalid in "$tasks/task.link" "$tmp/data-link/task-sessions-v2/task.issue1" "$tasks/./task.issue1" "$wt"; do
    reject 1 "$invalid_task" helper split-worktree "$invalid" "$checkout" issue 7 invalid "$base"
done
mkdir "$tmp/outside"
ln -s "$tmp/outside" "$fixes"
reject 1 '不安全的 fixes 目录。' split_issue invalid "$base"
reject 12 "$cleanup_blocked" helper cleanup-issue "$data" "$task" "$checkout" "$base" 7
[ -L "$fixes" ]
[ ! -e "$tmp/outside/invalid" ]
[ ! -e "$task/worktree-cleaned" ]
rm "$fixes"
mkdir "$fixes" "$fixes/taken"
ln -s "$tmp/missing" "$fixes/dangling"
for occupied in taken dangling; do
    reject 1 '拆分 worktree 路径已存在。' split_issue "$occupied" "$base"
done
[ -d "$fixes/taken" ]
[ -L "$fixes/dangling" ]
rmdir "$fixes/taken"
rm "$fixes/dangling"
rmdir "$fixes"

for driver in clean smudge process; do
    git -C "$checkout" config "filter.fixture.$driver" "touch '$tmp/filter-ran'; cat"
    reject 1 "$unsafe_config" split_issue filtered "$base"
    git -C "$checkout" config --unset "filter.fixture.$driver"
done
conditional=includeIf.onbranch:$branch-included.path
git config --file "$tmp/include.gitconfig" filter.fixture.smudge "touch '$tmp/filter-ran'; cat"
git -C "$checkout" config "$conditional" "$tmp/include.gitconfig"
reject 1 "$unsafe_config" split_issue included "$base"
git -C "$checkout" config --unset "$conditional"
[ ! -e "$tmp/filter-ran" ]
[ ! -e "$fixes" ]
[ ! -e "$task/.worktree-operation" ]
git -C "$checkout" show-ref > "$tmp/refs-after"
git -C "$checkout" worktree list --porcelain > "$tmp/worktrees-after"
cmp "$tmp/refs-before" "$tmp/refs-after"
cmp "$tmp/worktrees-before" "$tmp/worktrees-after"

assert_split() {
    output=$1 dest=$2 split_branch=$3
    [ "$output" = "$(printf '%s\n%s\n%s\n' "$dest" "$split_branch" "$base")" ]
    [ "$(git -C "$dest" rev-parse HEAD)" = "$base" ]
    [ "$(git -C "$dest" symbolic-ref HEAD)" = "refs/heads/$split_branch" ]
    [ -z "$(git -C "$dest" for-each-ref --format='%(upstream)' "refs/heads/$split_branch")" ]
    [ -z "$(git --no-optional-locks -C "$dest" status --porcelain=v1)" ]
    [ ! -e "$dest/aggregate" ]
    [ ! -e "$dest/notes" ]
    [ "$(cat "$dest/tracked")" = baseline ]
}
a=$fixes/fix-a
b=$fixes/fix_b
assert_split "$(split_issue fix-a "$base")" "$a" "$branch-fix-a"
printf 'only fix A\n' > "$a/only-a"
git -C "$a" add only-a
git -C "$a" commit -qm fix-a
a_head=$(git -C "$a" rev-parse HEAD)
upper_base=$(printf '%s' "$base" | tr 'a-f' 'A-F')
assert_split "$(split_issue fix_b "$upper_base")" "$b" "$branch-fix_b"
printf 'only fix B\n' > "$b/only-b"
git -C "$b" add only-b
git -C "$b" commit -qm fix-b
b_head=$(git -C "$b" rev-parse HEAD)
code=0
git -C "$b" merge-base --is-ancestor "$a_head" "$b_head" || code=$?
[ "$code" -eq 1 ]
[ "$(git -C "$b" merge-base "$a_head" "$b_head")" = "$base" ]
[ ! -e "$a/only-b" ]
[ ! -e "$b/only-a" ]
[ ! -e "$wt/only-a" ]
[ ! -e "$wt/only-b" ]

badge=$(helper issue-work "$checkout" "$data" "$task" "$base" "$tasks/task.missing" "$base")
[ "$badge" = "$(printf 'commits dirty split\nunavailable unknown\n')" ]
reject 12 "$cleanup_blocked" helper cleanup-issue "$data" "$task" "$checkout" "$base" 7 "$aggregate"
[ ! -e "$task/worktree-cleaned" ]
[ "$(git -C "$wt" rev-parse HEAD)" = "$aggregate" ]
[ "$(git -C "$wt" symbolic-ref HEAD)" = "refs/heads/$branch" ]
[ "$(cat "$wt/aggregate")" = 'aggregate commit' ]
cmp "$tmp/aggregate-index" "$index"
cmp "$tmp/aggregate-tracked" "$wt/tracked"
cmp "$tmp/aggregate-notes" "$wt/notes"
git --no-optional-locks -C "$wt" status --porcelain=v1 > "$tmp/status-after"
cmp "$tmp/aggregate-status" "$tmp/status-after"
[ "$(git -C "$checkout" rev-parse HEAD)" = "$base" ]
cmp "$tmp/checkout-tracked" "$checkout/tracked"

pr=$tasks/task.pr1
store=$pr/store.git
pr_wt=$pr/worktree
pr_branch=ternmate/pr-9-pr1
mkdir "$pr"
git init -q --bare --template= "$store"
cp "$store/config" "$pr/initial-git-config"
git --git-dir="$store" fetch -q "$checkout" "refs/heads/$branch"
git --git-dir="$store" update-ref refs/ternmate/initial "$aggregate"
git --git-dir="$store" worktree add -q --no-track -b "$pr_branch" -- "$pr_wt" "$aggregate"
pr_error='无法核对 PR 的私有 Git 存储、配置或原始 worktree。'
split_pr() { helper split-worktree "$pr" "$checkout" pr 9 "$@"; }
git --git-dir="$store" config core.warnAmbiguousRefs false
reject 1 "$pr_error" split_pr rejected "$base"
cp "$pr/initial-git-config" "$store/config"
touch "$store/worktrees/worktree/config.worktree"
reject 1 "$pr_error" split_pr rejected "$base"
rm "$store/worktrees/worktree/config.worktree"
git --git-dir="$store" update-ref -d refs/ternmate/initial
reject 1 '无法核对 PR 的初始提交引用。' split_pr rejected "$base"
git --git-dir="$store" update-ref refs/ternmate/initial "$aggregate"
[ ! -e "$pr/fixes" ]

mkdir "$pr/fixes"
ln -s "$tmp/missing" "$pr/fixes/.hidden"
reject 12 "$cleanup_blocked" helper cleanup-pr-check "$data" "$pr" "$aggregate" 9
reject 12 "$cleanup_blocked" helper cleanup-pr "$data" "$pr" "$aggregate" 9
[ -L "$pr/fixes/.hidden" ]
rm "$pr/fixes/.hidden"
helper cleanup-pr-check "$data" "$pr" "$aggregate" 9
assert_split "$(split_pr review-fix "$base")" "$pr/fixes/review-fix" "$pr_branch-review-fix"
reject 12 "$cleanup_blocked" helper cleanup-pr "$data" "$pr" "$aggregate" 9
[ "$(git -C "$pr_wt" rev-parse HEAD)" = "$aggregate" ]
[ "$(git -C "$pr_wt" symbolic-ref HEAD)" = "refs/heads/$pr_branch" ]
[ ! -e "$pr/worktree-cleaned" ]
[ -d "$a" ]
[ -d "$b" ]
[ -d "$pr/fixes/review-fix" ]
cmp "$pr/initial-git-config" "$store/config"
printf '%s\n' 'Independent Issue/PR worktrees retain exact bases, reject unsafe inputs, and prevent original cleanup.'
