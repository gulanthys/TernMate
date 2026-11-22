#!/bin/sh
# Tern's process API passes these arguments directly; this helper supplies
# file modes and a Git configuration boundary not available in the SDK.
set -eu
umask 077
PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}
export PATH

fail() { printf '%s\n' "$1" >&2; exit 1; }
physical() { (CDPATH= cd -P "$1" && pwd -P); }
private_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }

safe_git() (
    # No inherited repository locations, helpers/filters, redirects or Git tracing.
    # This does not clear gh's login environment or write its credentials anywhere.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_QUARANTINE_PATH \
        GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM \
        GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_EXTERNAL_DIFF GIT_SSL_NO_VERIFY \
        GIT_TRACE GIT_TRACE_PACKET GIT_TRACE_PACK_ACCESS GIT_TRACE_CURL GIT_CURL_VERBOSE \
        GIT_TRACE_PERFORMANCE GIT_TRACE_SETUP GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 \
        GIT_ALLOW_PROTOCOL=https GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false \
        GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
    export GH_PROMPT_DISABLED=1 GH_DEBUG= GIT_TRACE_REDACT=1
    exec git --no-optional-locks -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        -c core.attributesFile=/dev/null -c core.protectHFS=true -c core.protectNTFS=true \
        -c gc.auto=0 -c maintenance.auto=false "$@"
)

check_issue() (
    task=$1 checkout=$2
    wt=$task/worktree
    private_dir "$task" && private_dir "$wt" && regular "$wt/.git" || exit 1
    common=$(safe_git -C "$checkout" rev-parse --path-format=absolute --git-common-dir)
    admin=$(safe_git -C "$wt" rev-parse --absolute-git-dir)
    case "$admin" in "$common"/worktrees/*) ;; *) exit 1 ;; esac
    [ "$(safe_git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" = "$common" ] \
        && [ "$(safe_git -C "$wt" rev-parse --show-toplevel)" = "$wt" ] \
        && regular "$admin/gitdir" && [ "$(cat "$admin/gitdir")" = "$wt/.git" ] \
        && safe_git -C "$wt" rev-parse --verify 'HEAD^{commit}'
)

saved_pr_store() {
    private_dir "$task" && private_dir "$store" && { absent "$store/worktrees" || private_dir "$store/worktrees"; } \
        && regular "$store/config" && regular "$task/initial-git-config" \
        && cmp -s "$store/config" "$task/initial-git-config" \
        && [ ! -e "$store/config.worktree" ] && [ ! -L "$store/config.worktree" ] \
        && [ "$(safe_git --git-dir="$store" rev-parse --verify 'refs/ternmate/initial^{commit}')" = "$expected" ]
}

pr_cleanup_paths() {
    store=$task/store.git wt=$task/worktree admin=$task/store.git/worktrees/worktree
    marker=$task/worktree-cleaned
    branch=ternmate/pr-$number-${task##*.}
    ref=refs/heads/$branch
    saved="$expected $ref"
}

absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

clean_worktree() {
    for entry in index.lock locked MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-apply rebase-merge sequencer BISECT_START; do
        absent "$admin/$entry" || return 5
    done
    flags=$(safe_git -C "$wt" ls-files -v) || return 4
    if printf '%s\n' "$flags" | grep -q '^[a-zS] '; then return 5; fi
    # A submodule has its own Git config; do not run status or removal on it.
    entries=$(safe_git -C "$wt" ls-files --stage) || return 4
    if printf '%s\n' "$entries" | grep -q '^160000 '; then return 7; fi
    changes=$(safe_git -C "$wt" status --porcelain=v1 --untracked-files=all --ignored=matching --ignore-submodules=none) || return 4
    [ -z "$changes" ] || return 2
    worktrees=$(safe_git --git-dir="$store" worktree list --porcelain) || return 4
    [ "$(printf '%s\n' "$worktrees" | grep -Fxc "branch $ref")" = 1 ] || return 5
}

issue_filters_disabled() {
    if safe_git -C "$1" config --get-regexp '^filter\..*\.(process|clean|smudge)$' . >/dev/null; then
        return 1
    else
        [ "$?" -eq 1 ]
    fi
}

issue_archive_paths() {
    wt=$task/worktree marker=$task/worktree-cleaned
    store=$(safe_git -C "$checkout" rev-parse --path-format=absolute --git-common-dir) || return 4
    branch=ternmate/issue-$number-${task##*.}
    ref=refs/heads/$branch
    archive=refs/ternmate/archived/issue-$number-${task##*.}
}

load_cleanup_marker() {
    history_scope=
    regular "$marker" && [ "$(wc -c < "$marker")" -le 16384 ] || return 1
    {
        IFS= read -r marker_saved || return 1
        if IFS=' ' read -r history_scope history_at history_id history_kind history_number; then
            [ -n "$history_scope" ] && IFS= read -r history_store && IFS= read -r history_admin || return 1
        elif [ -n "$history_scope" ]; then
            return 1
        fi
    } < "$marker"
}

history_dir() {
    case "$1" in ''|*[!0-9a-f-]*) return 1 ;; esac
    history_root=$data/auto-cleanup-history-v1
    history=$history_root/$1
}

ensure_history_dirs() {
    for directory in "$history_root" "$history"; do
        private_dir "$directory" || mkdir "$directory" 2>/dev/null || private_dir "$directory" || return 1
    done
}

write_cleanup_marker() (
    if ! absent "$marker"; then
        load_cleanup_marker && [ "$marker_saved" = "$saved" ] || exit 4
    fi
    scope=${TERNMATE_CLEANUP_HISTORY:-}
    if [ -n "$scope" ]; then
        history_dir "$scope" && ensure_history_dirs || exit 10
        stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || exit 10
    fi
    temp=$(mktemp "$task/.worktree-cleaned.XXXXXXXXXX") || exit 4
    trap 'rm -f -- "$temp"' EXIT
    # Keep the pending receipt in the same atomic record that permits restore.
    # Unlike the temporary file, this record survives interruption and publish failure.
    {
        printf '%s\n' "$saved" || exit 4
        if [ -n "$scope" ]; then
            printf '%s %s %s %s %s\n%s\n%s\n' "$scope" "$stamp" "${temp##*.}" "$1" "$number" "$store" "$admin" || exit 10
        fi
    } > "$temp" || exit 4
    mv -f -- "$temp" "$marker" || exit 4
)

history_event_matches() {
    private_dir "$history_root" && private_dir "$history" && regular "$event" \
        && [ "$(wc -c < "$event")" -le 512 ] && [ "$(cat "$event")" = "$row" ]
}

reconcile_history() (
    [ -n "$history_scope" ] || exit 0
    history_dir "$history_scope" || exit 1
    suffix=${task#"$data"/task-sessions-v2/task.}
    case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 1 ;; esac
    case "$history_at" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) exit 1 ;;
    esac
    case "$history_id" in ''|*[!a-zA-Z0-9]*) exit 1 ;; esac
    case "$history_number" in ''|*[!0-9]*) exit 1 ;; esac
    case "$history_kind" in issue) kind=issue ;; pr|review) kind=pr ;; *) exit 1 ;; esac
    branch=ternmate/$kind-$history_number-$suffix
    ref=refs/heads/$branch
    expected=${marker_saved%% *}
    case "$expected" in ''|*[!0-9a-f]*) exit 1 ;; esac
    [ "${#expected}" -eq 40 ] || [ "${#expected}" -eq 64 ] || exit 1
    [ "$marker_saved" = "$expected $ref" ] || exit 1
    row=$(printf '%s\t%s\t%s\t%s\t%s' "$history_at" "$history_kind" "$history_number" "$branch" "$expected")
    event=$history/$history_at.$suffix.$history_id.event
    if history_event_matches; then exit 0; fi

    # A marker alone also survives a failed removal. Require both the worktree
    # and the branch to be gone, and the exact commit to still be restorable.
    store=$history_store admin=$history_admin
    absent "$task/worktree" && absent "$admin" || exit 0
    if [ "$kind" = pr ]; then
        [ "$store" = "$task/store.git" ] && [ "$admin" = "$store/worktrees/worktree" ] && saved_pr_store || exit 1
    else
        case "$store" in /*) ;; *) exit 1 ;; esac
        case "$admin" in "$store"/worktrees/*) ;; *) exit 1 ;; esac
        private_dir "$store" && { absent "$store/worktrees" || private_dir "$store/worktrees"; } || exit 1
        archive=refs/ternmate/archived/issue-$history_number-$suffix
        [ "$(safe_git --git-dir="$store" rev-parse --verify "$archive")" = "$expected" ] || exit 1
    fi
    # A quiet show-ref also reports failure for invalid refs; do not take a Git
    # error or warning as proof of absence.
    refs=$(safe_git --git-dir="$store" for-each-ref --format='%(refname)' "$ref" 2>&1) || exit 1
    case "$refs" in '') ;; "$ref"|"$ref/"*) exit 0 ;; *) exit 1 ;; esac
    worktrees=$(safe_git --git-dir="$store" worktree list --porcelain) || exit 1
    if printf '%s\n' "$worktrees" | grep -Fxq "branch $ref"; then exit 0; fi

    ensure_history_dirs || exit 1
    if ! absent "$event"; then history_event_matches; exit; fi
    receipt=$(mktemp "$history/.event.XXXXXXXXXX") || exit 1
    trap 'rm -f -- "$receipt"' EXIT
    printf '%s\n' "$row" > "$receipt" || exit 1
    # Concurrent readers publish the same bytes under the same name.
    if mv -f -- "$receipt" "$event" && regular "$event"; then
        trap - EXIT
    else
        history_event_matches
    fi
)

reconcile_pending_history() (
    root=$data/task-sessions-v2
    if absent "$root"; then exit 0; fi
    private_dir "$root" || exit 1
    for marker in "$root"/task.*/worktree-cleaned; do
        task=${marker%/*}
        if private_dir "$task" && load_cleanup_marker && [ "$history_scope" = "$1" ]; then
            reconcile_history || exit 1
        fi
    done
)

exe() { [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ]; }
which_tool() {
    found=$(command -v "$1" || :)
    case "$found" in /*) if exe "$found"; then printf '%s\n' "$found"; return; fi ;; esac
    shift
    for candidate do
        if exe "$candidate"; then printf '%s\n' "$candidate"; return; fi
    done
    return 1
}

case "$1" in
    cleanup-history)
        data=$(physical "$2") || exit 1
        history_dir "$3" || exit 1
        reconcile_pending_history "$3" || exit 1
        if ! absent "$history_root"; then
            private_dir "$history_root" || exit 1
            if ! absent "$history"; then
                private_dir "$history" || exit 1
                LC_ALL=C
                export LC_ALL
                for event in "$history"/*.event; do
                    if absent "$event"; then continue; fi
                    regular "$event" && [ "$(wc -c < "$event")" -le 512 ] || exit 1
                    cat "$event" || exit 1
                done
            fi
        fi
        printf '%s\n' end
        ;;
    tern)
        which_tool tern "${HOME:-}/.local/bin/tern" "/Applications/Tern.app/Contents/MacOS/tern" \
            "${HOME:-}/Applications/Tern.app/Contents/MacOS/tern" || fail '找不到 Tern CLI。'
        ;;
    omp)
        for candidate in "${TERN_CONFIG_DIR:-$2}/omp/bin/omp" "$2/omp/bin/omp" \
            "${HOME:-}/Library/Application Support/Tern/omp/bin/omp"; do
            if exe "$candidate"; then printf '%s\n' "$candidate"; exit; fi
        done
        which_tool omp "${HOME:-}/.local/bin/omp" "${HOME:-}/.omp/bin/omp" || fail '找不到可执行的 omp。'
        ;;
    source)
        selected=$(physical "$2") || fail '所选 checkout 已不存在。'
        root=$(safe_git -C "$selected" rev-parse --path-format=absolute --show-toplevel) || fail '所选 checkout 不在 Git 工作区。'
        root=$(physical "$root") || fail '所选 Git 根目录已不存在。'
        [ "$root" = "$selected" ] || fail '所选 checkout 不是工作区根目录。'
        data=$(physical "$3") || fail 'Tern 插件数据目录不可用。'
        case "$data/" in "$root/"*) fail '插件数据目录位于 checkout 内；不能保存私有任务材料。';; esac
        [ "$root" != / ] || fail '不能为根目录 checkout 保存外部任务材料。'
        printf '%s\n%s\n' "$root" "$data"
        ;;
    same-cwd)
        actual=$(physical "$2") && expected=$(physical "$3") && [ "$actual" = "$expected" ]
        ;;
    allocate)
        root=$2/task-sessions-v2
        if ! mkdir -m 700 "$root" 2>/dev/null; then
            private_dir "$root" || fail '不能创建安全的任务存储目录。'
        fi
        chmod 700 "$root"
        task=$(mktemp -d "$root/task.XXXXXXXXXX")
        mkdir -m 700 "$task/session"
        printf '%s\n' "$task"
        ;;
    material)
        private_dir "$2" && [ ! -e "$2/materials.md" ] && [ ! -L "$2/materials.md" ] || fail '不能写入私有任务材料。'
        if [ "${3:-}" = baseline ]; then
            baseline=$2/pr-comments.baseline.json
            [ ! -e "$baseline" ] && [ ! -L "$baseline" ] || fail '不能写入私有评论基线。'
            IFS= read -r seen && [ -n "$seen" ] || fail '缺少私有评论基线。'
            printf '%s' "$seen" > "$baseline"
            [ "$(wc -c < "$baseline")" -le 458752 ] || fail '评论基线超过上限。'
        fi
        cat > "$2/materials.md"
        ;;
    comment-state)
        task=$2
        private_dir "$task" || fail '无效的私有任务目录。'
        state=$task/pr-comments.json
        receipt=$task/pr-comments.receipt
        baseline=$task/pr-comments.baseline.json
        if [ "${3:-}" != initial ] && { [ -e "$state" ] || [ -L "$state" ]; }; then
            regular "$state" && [ "$(wc -c < "$state")" -le 524288 ] || fail '评论投递记录无效。'
            if [ -e "$receipt" ] || [ -L "$receipt" ]; then
                regular "$receipt" && [ "$(wc -c < "$receipt")" -le 32 ] || fail '评论投递回执无效。'
                cat "$receipt"
            else
                printf '0\n'
            fi
            cat "$state"
        else
            regular "$task/materials.md" || fail '原始 PR 材料不可读。'
            if [ -e "$baseline" ] || [ -L "$baseline" ]; then
                regular "$baseline" && [ "$(wc -c < "$baseline")" -le 458752 ] || fail '评论基线无效。'
                printf 'baseline\n'
                cat "$baseline"
            else
                [ "$(wc -c < "$task/materials.md")" -le 458752 ] || fail '原始 PR 材料超过上限。'
                printf 'initial\n'
                cat "$task/materials.md"
            fi
        fi
        ;;
    comment-queue)
        task=$2
        private_dir "$task" || fail '无效的私有任务目录。'
        state=$task/pr-comments.json
        [ ! -L "$state" ] && { [ ! -e "$state" ] || regular "$state"; } || fail '评论投递路径已被替换。'
        temp=$(mktemp "$task/.pr-comments.XXXXXXXXXX")
        trap 'rm -f -- "$temp"' EXIT
        cat > "$temp"
        [ "$(wc -c < "$temp")" -le 524288 ] || fail '评论投递记录超过上限。'
        mv -f -- "$temp" "$state"
        ;;
    pr-prompt)
        task=$2 program=$3 checkout=$4
        private_dir "$task" && exe "$program" || fail '不能准备可信 PR 提示。'
        agent=$(cd / && "$program" config path) || fail '无法确定 OMP 的全局配置目录。'
        case "$agent" in /*) ;; *) fail 'OMP 全局配置路径不是绝对路径。';; esac
        case "$agent" in *[[:cntrl:]]*) fail 'OMP 全局配置路径无效。';; esac
        dest=$task/system-prompt.md
        [ ! -L "$dest" ] && { [ ! -e "$dest" ] || regular "$dest"; } || fail '私有 PR 提示路径已被替换。'
        temp=$(mktemp "$task/.system-prompt.XXXXXXXXXX")
        trap 'rm -f -- "$temp"' EXIT
        {
            rules=$agent/RULES.md
            if [ -e "$rules" ] || [ -L "$rules" ]; then
                agent=$(physical "$agent") || fail '不能核对 OMP 全局配置路径。'
                case "$agent/" in "$checkout/"*|"${task%/*}/"*) fail '不能从 checkout 或任务工作区加载规则。';; esac
                regular "$agent/RULES.md" || fail 'OMP 全局 RULES.md 必须是普通文件。'
                cat "$agent/RULES.md"
                printf '\n\n'
            fi
            # The fixed task boundary comes last; global guidance is not authorization.
            cat
        } > "$temp"
        mv -f -- "$temp" "$dest"
        ;;
    issue-head)
        safe_git -C "$2" rev-parse --verify 'HEAD^{commit}'
        ;;
    prepare-issue)
        task=$2 checkout=$3 number=$4
        head=$5
        safe_git -C "$checkout" rev-parse --verify "$head^{commit}" >/dev/null || exit 3
        # A linked worktree inherits repository config. Do not run a
        # repo-local checkout filter on a read-only Issue activation.
        if safe_git -C "$checkout" config --get-regexp '^filter\..*\.(process|smudge)$' . >/dev/null; then
            exit 4
        else
            [ "$?" -eq 1 ] || fail '无法核对 checkout 的 Git filter 配置。'
        fi
        safe_git -C "$checkout" -c submodule.recurse=false worktree add --no-track \
            -b "ternmate/issue-$number-${task##*.}" -- "$task/worktree" "$head" >&2
        ;;
    check-issue)
        if absent "$2/worktree" && regular "$2/worktree-cleaned"; then exit 6; fi
        check_issue "$2" "$3" >/dev/null
        ;;
    cleanup-issue|restore-issue)
        operation=$1
        data=$(physical "$2") || exit 4
        task=$3 checkout=$4 base=$5 number=$6
        shift 6
        suffix=${task#"$data"/task-sessions-v2/task.}
        case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 4 ;; esac
        case "$number" in ''|*[!0-9]*) exit 4 ;; esac
        private_dir "$data/task-sessions-v2" && private_dir "$task" || exit 4
        issue_archive_paths || exit 4
        if [ "$operation" = restore-issue ]; then
            absent "$wt" && regular "$marker" && issue_filters_disabled "$checkout" || exit 4
            head=$(safe_git --git-dir="$store" rev-parse --verify "$archive^{commit}") || exit 4
            load_cleanup_marker && [ "$marker_saved" = "$head $ref" ] || exit 4
            reconcile_history || fail '无法保存待恢复工作区的自动清理历史；请稍后重试。'
            if safe_git --git-dir="$store" show-ref --verify --quiet "$ref"; then
                [ "$(safe_git --git-dir="$store" rev-parse --verify "$ref")" = "$head" ] || exit 4
                safe_git -C "$checkout" -c submodule.recurse=false worktree add -- "$wt" "$branch" >&2
            else
                safe_git -C "$checkout" -c submodule.recurse=false worktree add --no-track -b "$branch" -- "$wt" "$head" >&2
            fi
            rm -- "$marker"
            safe_git --git-dir="$store" update-ref -d "$archive" "$head"
            exit
        fi
        if absent "$wt" && regular "$marker"; then exit 8; fi
        head=$(check_issue "$task" "$checkout") || exit 4
        [ "$(safe_git -C "$wt" symbolic-ref --quiet HEAD)" = "$ref" ] || exit 3
        if [ "$head" != "$base" ]; then
            linked=false
            for merged in "$@"; do
                if safe_git -C "$wt" merge-base --is-ancestor "$head" "$merged" 2>/dev/null; then linked=true; break; fi
            done
            [ "$linked" = true ] || exit 3
        fi
        issue_filters_disabled "$wt" || exit 4
        admin=$(safe_git -C "$wt" rev-parse --absolute-git-dir) || exit 4
        clean_worktree || exit "$?"
        if safe_git --git-dir="$store" show-ref --verify --quiet "$archive"; then
            [ "$(safe_git --git-dir="$store" rev-parse --verify "$archive")" = "$head" ] || exit 4
        else
            zero=$(printf '%s' "$head" | tr '0-9a-f' '0')
            safe_git --git-dir="$store" update-ref "$archive" "$head" "$zero" || exit 4
        fi
        saved="$head $ref"
        write_cleanup_marker issue
        safe_git --git-dir="$store" worktree remove -- "$wt" || exit 5
        worktrees=$(safe_git --git-dir="$store" worktree list --porcelain) || exit 9
        if printf '%s\n' "$worktrees" | grep -Fxq "branch $ref"; then exit 9; fi
        safe_git --git-dir="$store" update-ref -d "$ref" "$head" || exit 9
        load_cleanup_marker && reconcile_history || exit 11
        ;;
    workspace-list)
        data=$(physical "$2") || exit 1
        private_dir "$data" || exit 1
        root=$data/task-sessions-v2
        if ! absent "$root"; then
            private_dir "$root" || exit 1
            for task in "$root"/task.*; do
                name=${task##*/}
                case "${name#task.}" in ''|*[!a-zA-Z0-9]*) continue ;; esac
                if private_dir "$task" && private_dir "$task/worktree"; then printf '%s\n' "$name"; fi
            done
        fi
        printf '%s\n' end
        ;;
    issue-work)
        checkout=$2
        data=$(physical "$3") || exit 1
        shift 3
        while [ "$#" -ge 2 ]; do
            task=$1 base=$2 wt=$1/worktree
            shift 2
            suffix=${task#"$data"/task-sessions-v2/task.}
            case "$suffix" in ''|*[!a-zA-Z0-9]*) printf 'unavailable unknown\n'; continue ;; esac
            case "$base" in ''|*[!0-9a-f]*) printf 'unknown unknown\n'; continue ;; esac
            if absent "$wt" && regular "$task/worktree-cleaned"; then
                printf 'archived archived\n'
                continue
            fi
            if ! head=$(check_issue "$task" "$checkout" 2>/dev/null); then
                printf 'unavailable unknown\n'
                continue
            fi
            lineage=unknown
            if [ "$head" = "$base" ]; then
                lineage=initial
            elif safe_git -C "$wt" merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
                lineage=commits
            elif [ "$?" -eq 1 ]; then
                lineage=diverged
            fi
            dirty=unknown
            # A linked worktree can inherit custom clean filters; never run them for a badge.
            if safe_git -C "$wt" config --get-regexp '^filter\..*\.(process|clean)$' . >/dev/null 2>&1; then
                :
            elif [ "$?" -eq 1 ] && changes=$(safe_git -C "$wt" -c submodule.recurse=false \
                status --porcelain=v1 --untracked-files=normal --ignore-submodules=dirty 2>/dev/null); then
                if [ -n "$changes" ]; then
                    dirty=dirty
                elif entries=$(safe_git -C "$wt" ls-files --stage 2>/dev/null); then
                    # Do not execute repository-local filters inside submodules.
                    if printf '%s\n' "$entries" | grep -q '^160000 '; then
                        dirty=unchecked
                    else
                        dirty=clean
                    fi
                fi
            fi
            printf '%s %s\n' "$lineage" "$dirty"
        done
        [ "$#" -eq 0 ]
        ;;
    prepare)
        task=$2 url=$3 ref=$4 expected=$5 number=$6 review_base=${7:-} review_ref=${8:-}
        if [ -n "$review_base" ] || [ -n "$review_ref" ]; then
            [ -n "$review_base" ] && safe_git check-ref-format "refs/heads/$review_ref" >/dev/null \
                || fail '审核用的 PR base SHA 或分支无效。'
        fi
        cd -P "$task"
        safe_git init -q --bare --template= store.git
        cp store.git/config initial-git-config
        # The repository is fresh and has no filter drivers or remotes. The URL
        # and ref are individually validated by Luau; no ref in the original
        # checkout is read or written. Git invokes its fixed credential bridge.
        if ! safe_git --git-dir=store.git -c http.followRedirects=false -c credential.helper= \
            -c 'credential.helper=!gh auth git-credential' -c fetch.fsckObjects=true \
            fetch -q --no-tags --no-recurse-submodules -- "$url" "$ref" 2>/dev/null; then
            fail '不能通过 HTTPS 获取所选 PR 引用；确认 gh 登录、读取权限和网络。'
        fi
        fetched=$(safe_git --git-dir=store.git rev-parse --verify 'FETCH_HEAD^{commit}')
        if [ "$fetched" != "$expected" ]; then printf '%s\n' "$fetched"; exit 3; fi
        safe_git --git-dir=store.git worktree add -b "ternmate/pr-$number-${task##*.}" -- "$task/worktree" "$expected" >&2
        actual=$(safe_git -C worktree rev-parse --verify 'HEAD^{commit}')
        [ "$actual" = "$expected" ] || fail '新 worktree 的 HEAD 不等于已验证的 PR 提交。'
        # Retain the original PR commit even after local commits change HEAD.
        safe_git --git-dir=store.git update-ref refs/ternmate/initial "$expected"
        if [ -n "$review_base" ]; then
            if ! safe_git --git-dir=store.git cat-file -e "$review_base^{commit}" 2>/dev/null; then
                safe_git --git-dir=store.git -c http.followRedirects=false -c credential.helper= \
                    -c 'credential.helper=!gh auth git-credential' -c fetch.fsckObjects=true \
                    fetch -q --no-tags --no-recurse-submodules -- "$url" "$review_base" 2>/dev/null \
                    || fail '无法获取审核用的 PR base 提交。'
            fi
            safe_git --git-dir=store.git update-ref refs/ternmate/review-base "$review_base"
            base=$(safe_git --git-dir=store.git merge-base "$review_base" "$expected") \
                || fail '无法核对 PR 的共同祖先。'
            # Bound the private evidence file without confusing an empty diff with a Git failure.
            limit=524288
            if ! {
                if safe_git --git-dir=store.git diff --no-ext-diff --no-textconv --no-color "$base" "$expected" --; then
                    : > .review-diff-ok
                fi
            } | (head -c "$limit" && cat >/dev/null) > review.diff; then
                fail '无法写入固定版本的 PR 差异。'
            fi
            [ -f .review-diff-ok ] || fail '无法生成固定版本的 PR 差异。'
            if [ "$(wc -c < review.diff)" -ge "$limit" ]; then
                printf '\n[Diff size limit reached. Evidence may be truncated.]\n' >> review.diff
            fi
            rm -f -- .review-diff-ok
            diff_oid=$(safe_git --git-dir=store.git hash-object --no-filters -- review.diff)
            printf '%s\n%s\n' "$review_ref" "$diff_oid" > review-evidence
        fi
        ;;
    cleanup-pr-check|cleanup-pr)
        data=$(physical "$2") || exit 4
        task=$3 expected=$4 number=$5
        suffix=${task#"$data"/task-sessions-v2/task.}
        case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 4 ;; esac
        case "$number" in ''|*[!0-9]*) exit 4 ;; esac
        case "$expected" in ''|*[!0-9a-f]*) exit 4 ;; esac
        [ "${#expected}" -eq 40 ] || exit 4
        private_dir "$data/task-sessions-v2" || exit 4
        pr_cleanup_paths
        if absent "$wt" && absent "$admin" && load_cleanup_marker && [ "$marker_saved" = "$saved" ]; then exit 8; fi
        saved_pr_store || exit 4
        private_dir "$wt" && private_dir "$admin" && regular "$wt/.git" && regular "$admin/gitdir" \
            && [ "$(cat "$wt/.git")" = "gitdir: $admin" ] && [ "$(cat "$admin/gitdir")" = "$wt/.git" ] \
            && absent "$admin/config.worktree" || exit 4
        [ "$(safe_git -C "$wt" symbolic-ref --quiet HEAD)" = "$ref" ] \
            && [ "$(safe_git -C "$wt" rev-parse --verify 'HEAD^{commit}')" = "$expected" ] || exit 3
        clean_worktree || exit "$?"
        if [ "$1" = cleanup-pr-check ]; then exit 0; fi
        write_cleanup_marker "${TERNMATE_CLEANUP_MODE:-pr}"
        safe_git --git-dir="$store" worktree remove -- "$wt" || exit 5
        worktrees=$(safe_git --git-dir="$store" worktree list --porcelain) || exit 9
        if printf '%s\n' "$worktrees" | grep -Fxq "branch $ref"; then exit 9; fi
        safe_git --git-dir="$store" update-ref -d "$ref" "$expected" || exit 9
        load_cleanup_marker && reconcile_history || exit 11
        ;;
    restore-pr)
        task=$2 expected=$3 number=$4
        pr_cleanup_paths
        absent "$wt" && absent "$admin" && load_cleanup_marker && [ "$marker_saved" = "$saved" ] \
            && saved_pr_store || fail '不能安全重建已清理的 PR worktree。'
        if [ -n "$history_scope" ]; then
            data=$(physical "$task/../..") && reconcile_history || fail '无法保存待恢复工作区的自动清理历史；请稍后重试。'
        fi
        if safe_git --git-dir="$store" show-ref --verify --quiet "$ref"; then
            [ "$(safe_git --git-dir="$store" rev-parse --verify "$ref")" = "$expected" ] || fail '保留的分支已变化。'
            safe_git --git-dir="$store" worktree add -- "$wt" "$branch" >&2
        else
            safe_git --git-dir="$store" worktree add -b "$branch" -- "$wt" "$expected" >&2
        fi
        rm -- "$marker"
        ;;
    check|check-review|push-source)
        task=$2 expected=$3
        wt=$task/worktree
        admin=$task/store.git/worktrees/worktree
        if [ "$1" != push-source ] && absent "$wt" && absent "$admin" && regular "$task/worktree-cleaned"; then exit 6; fi
        private_dir "$task" && private_dir "$wt" && private_dir "$task/store.git" && private_dir "$admin" \
            && regular "$wt/.git" && regular "$admin/gitdir" \
            || fail 'PR worktree 已不存在或目录结构已变化；未触碰保留的工作区。'
        [ "$(cat "$wt/.git")" = "gitdir: $admin" ] && [ "$(cat "$admin/gitdir")" = "$wt/.git" ] \
            || fail 'PR worktree 不再指向此任务的 Git 存储。'
        [ "$(safe_git -C "$wt" rev-parse --verify 'refs/ternmate/initial^{commit}')" = "$expected" ] \
            || fail 'PR worktree 的初始提交记录已失效。'
        head=$(safe_git -C "$wt" rev-parse --verify 'HEAD^{commit}')
        if [ "$1" = push-source ]; then
            safe_git check-ref-format "$4" >/dev/null || exit 2
            [ "$head" != "$expected" ] || exit 3
            safe_git -C "$wt" merge-base --is-ancestor "$expected" "$head" || exit 4
            printf '%s\n' "$head"
            exit
        fi
        if [ "$1" = check-review ]; then
            review_base=$4 review_ref=$5
            [ "$head" = "$expected" ] && regular "$task/review.diff" && regular "$task/review-evidence" \
                && [ "$(safe_git -C "$wt" rev-parse --verify 'refs/ternmate/review-base^{commit}')" = "$review_base" ] \
                || fail '审核的 head、base SHA 或差异已变化。'
            diff_oid=$(safe_git -C "$wt" hash-object --no-filters -- "$task/review.diff")
            [ "$(cat "$task/review-evidence")" = "$(printf '%s\n%s\n' "$review_ref" "$diff_oid")" ] \
                || fail '审核的 base 分支或差异内容已变化。'
        fi
        printf '%s\n' "$head"
        # Checking status can run a clean filter. Never do so if a user has
        # modified the fresh repository's configuration or added worktree config.
        if regular "$task/store.git/config" && regular "$task/initial-git-config" \
            && cmp -s "$task/store.git/config" "$task/initial-git-config" \
            && [ ! -e "$admin/config.worktree" ] && [ ! -L "$admin/config.worktree" ]; then
            changes=$(safe_git -C "$wt" status --porcelain=v1 --untracked-files=normal --ignore-submodules=all)
            if [ -n "$changes" ]; then printf 'dirty\n'; else printf 'clean\n'; fi
        else
            printf 'unknown\n'
        fi
        ;;
    file)
        private_dir "$2" && regular "$3" && [ -s "$3" ] || exit 1
        LC_ALL=C head -c 16384 "$3" | head -n 2
        ;;
    session-empty)
        private_dir "${2%/*}" && private_dir "$2" || fail '私有会话目录已失效。'
        # Unlike discover, count even hidden, empty, malformed or non-regular entries.
        # A failed listing must never be mistaken for an empty directory.
        entries=$(CDPATH= cd -P "$2" && find . ! -name . -prune -print) || fail '无法读取私有会话目录。'
        [ -z "$entries" ] || exit 3
        ;;
    discover)
        private_dir "$2" || fail '私有会话目录已失效。'
        count=0
        for file in "$2"/*.jsonl; do
            if regular "$file" && [ -s "$file" ]; then
                printf '%s\n' "$file"
                count=$((count + 1))
                [ "$count" -lt 2 ] || break
            fi
        done
        ;;
    *) exit 2 ;;
esac
