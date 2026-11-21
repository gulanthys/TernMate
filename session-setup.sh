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
        cat > "$2/materials.md"
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
        task=$2 checkout=$3
        wt=$task/worktree
        private_dir "$task" && private_dir "$wt" && regular "$wt/.git" || exit 1
        common=$(safe_git -C "$checkout" rev-parse --path-format=absolute --git-common-dir)
        admin=$(safe_git -C "$wt" rev-parse --absolute-git-dir)
        case "$admin" in "$common"/worktrees/*) ;; *) exit 1 ;; esac
        [ "$(safe_git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" = "$common" ] \
            && [ "$(safe_git -C "$wt" rev-parse --show-toplevel)" = "$wt" ] \
            && regular "$admin/gitdir" && [ "$(cat "$admin/gitdir")" = "$wt/.git" ] \
            && safe_git -C "$wt" rev-parse --verify 'HEAD^{commit}' >/dev/null
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
    check|check-review|push-source)
        task=$2 expected=$3
        wt=$task/worktree
        admin=$task/store.git/worktrees/worktree
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
