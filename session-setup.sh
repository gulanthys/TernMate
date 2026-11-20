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
        root=$2/task-sessions-v1
        if ! mkdir -m 700 "$root" 2>/dev/null; then
            private_dir "$root" || fail '不能创建安全的任务存储目录。'
        fi
        chmod 700 "$root"
        task=$(mktemp -d "$root/task.XXXXXXXXXX")
        mkdir -m 700 "$task/session"
        # Extra CLI configuration (higher precedence than project settings).
        printf '%s\n' 'mcp:' '  enableProjectConfig: false' 'autoResume: false' 'shellPath: /bin/sh' > "$task/omp.yml"
        printf '%s\n' "$task"
        ;;
    material)
        private_dir "$2" && [ ! -e "$2/materials.md" ] && [ ! -L "$2/materials.md" ] || fail '不能写入私有任务材料。'
        cat > "$2/materials.md"
        ;;
    prepare)
        task=$2 url=$3 ref=$4 expected=$5
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
        safe_git --git-dir=store.git worktree add --detach -- "$task/worktree" "$expected" >&2
        actual=$(safe_git -C worktree rev-parse --verify 'HEAD^{commit}')
        [ "$actual" = "$expected" ] || fail '新 worktree 的 HEAD 不等于已验证的 PR 提交。'
        # Retain the original PR commit even after local commits change HEAD.
        safe_git --git-dir=store.git update-ref refs/ternmate/initial "$expected"
        ;;
    check)
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
