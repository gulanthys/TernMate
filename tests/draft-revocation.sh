#!/bin/sh
# Run with LUAU=/path/to/luau sh tests/draft-revocation.sh. No Tern, gh, or disk records are needed.
set -eu
root=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-draft-test.XXXXXXXX")
trap 'rm -rf "$root"' EXIT
trap 'exit 1' HUP INT TERM
src=$(dirname "$0")/..
{
    cat <<'LUAU'
local repo = {host="github.com", owner="org", name="repo"}
local function identity(viewer, repoId)
    return {repoId=repoId or "repo-1", viewerId=viewer, viewer=viewer, webUrl="https://github.com/org/repo",
        visibility="PRIVATE", hasIssues=true, isFork=false, defaultBranch="main"}
end
local a, b, replaced = identity("alice"), identity("bob"), identity("alice", "repo-2")
local key = "submit-draft-1"
local secret = "old identity's private draft"
local block, fixture
local function node(kind, props, children)
    return {kind=kind, props=props, children=children}
end
local ui = {
    node=node, span=function(text) return text end, text=function(spans) return spans end,
    badge=function(text) return text end,
    button=function(text, props) return {text, props} end,
    row=function(children) return children end, col=function(children) return children end,
    card=function(_, children) return children end, progress=function(_, text) return text end,
}
local tern = {ui=ui, json={encode=function(value) return value end, null={}},
    block={define=function(_, def) block=def end}}
tern.now = function() return 400000 end
tern.timer = function(delay, callback)
    if delay == 0 then callback() end
    return {cancel=function() end}
end
local function partition(info)
    return info.repoId .. "/" .. info.viewerId
end
local modules = {
    ["./runtime"]={
        alive=function() return true end,
        trim=function(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end,
        repoKey=function(r) return r.host .. "/" .. r.owner .. "/" .. r.name end,
        json=function(value, err) return value, err end,
        exec=function(argv, _, done)
            if argv[1] == "gh" then
                assert(argv[2] == "api", "unexpected GitHub operation")
                table.insert(fixture.queries, done)
            else
                assert(argv[1] == "/usr/bin/ruby", "unexpected local process")
                done({["config.yml"]={blank_issues_enabled=true}})
            end
        end,
    },
    ["./sessions"]={issueBadges=function() return function() return "" end end},
    ["./maintenance_data"]={
        identity=function(_, done) table.insert(fixture.identities, done) end,
        cached=function(_, _, done)
            if fixture.pauseCache then fixture.cacheReply=done else done(fixture.cache) end
        end,
        resultRevision=function(_, info, done)
            assert(partition(info) == partition(a))
            fixture.revisionReply=done
        end,
        sync=function(_, _, baseline, alive, done, progress, visible)
            table.insert(fixture.scans, {baseline=baseline, alive=alive, done=done, progress=progress, visible=visible})
            fixture.sync=done
        end,
        createIssue=function(_, info, slot, draft, title, body, _, done)
            table.insert(fixture.sends, {scope=partition(info), slot=slot, draft=draft, title=title, body=body, visibility=info.visibility})
            if fixture.pauseSend then fixture.completeSend=done else done("auth_unavailable") end
        end,
        store=function(_, info, record, op, value, done)
            local records = fixture.records
            local scope = partition(info)
            table.insert(fixture.calls, {scope=scope, key=record, op=op})
            local function finish()
                records[scope] = records[scope] or {}
                if op == "read" then done(records[scope][record])
                elseif op == "draft-save" then
                    local current = records[scope][record]
                    if records[scope]["submit-lock-1"] then done({status="locked"})
                    elseif current ~= value.expected then done({status="conflict", draft=current})
                    else records[scope][record]=value.replacement; done({status="saved"}) end
                elseif op == "draft-settle" then
                    if records[scope][record] then done({status="locked"})
                    elseif records[scope][key] ~= value.expected then done({status="conflict"})
                    else records[scope][record]=value.replacement; done({status="settled"}) end
                elseif op == "create" then
                    assert(not records[scope][record], "record was saved twice")
                    records[scope][record]=value; done(true)
                elseif op == "remove" then
                    if fixture.removeError then done(nil, fixture.removeError)
                    else records[scope][record]=nil; done(true) end
                else error("unexpected store mode: " .. op) end
            end
            if fixture.pause == op .. ":" .. record then
                fixture.pause, fixture.pending = nil, finish
            else finish() end
        end,
    },
}
local function require(name) return assert(modules[name], name) end
LUAU
    printf '%s\n' 'modules["./github"] = (function()'
    cat "$src/github.luau"
    printf '%s\n' 'end)()' 'modules["./github"].discover = function(_, _, _, done) done("/fixture", {repo}) end'
    printf '%s\n' 'modules["./issue_submit"] = (function()'
    cat "$src/issue_submit.luau"
    printf '%s\n' 'end)()' 'local newIssue = modules["./issue_submit"].new' \
        'modules["./issue_submit"].new = function(ctx) fixture.submitContext = ctx; return newIssue(ctx) end' '(function()'
    cat "$src/host.luau"
    printf '%s\n' 'end)()'
    cat <<'LUAU'
local cx = {pane=1, rows=30, render=function() end, frame=function() end}
local function start(cache)
    fixture = {cache=cache, scans={}, identities={}, queries={}, calls={}, sends={}, records={
        [partition(a)]={[key]={title=secret, form="blank", version="main\ndir\n", fields={}}},
    }}
    fixture.state = block.init(cx, {"/fixture"}, nil)
end
local function act(action, value)
    block.event(fixture.state, {ev="action", act=action, value=value}, cx)
end
local function respond(index, info)
    assert(fixture.identities[index], "missing identity request")(info)
end
local function templates(index, info)
    local config = "blank_issues_enabled: true"
    assert(fixture.queries[index], "missing template request")({data={viewer={id=info.viewerId, login=info.viewer},
        repository={id=info.repoId, nameWithOwner="org/repo", hasIssuesEnabled=true, visibility=info.visibility, isFork=false,
            defaultBranchRef={name="main"}, dir={oid="dir", entries={{name="config.yml", mode=33188,
                object={oid="config", text=config, byteSize=#config, isBinary=false, isTruncated=false}}}}},
    }})
end
local function contains(value, text)
    if type(value) == "string" then return value:find(text, 1, true) ~= nil end
    if type(value) == "table" then
        for _, child in value do if contains(child, text) then return true end end
    end
    return false
end
local function shows(text) return contains(block.view(fixture.state, cx), text) end
local function editTitle(waitFor)
    act("submit:resume")
    act("submit:title")
    block.key(fixture.state, {name="x", text="x"}, cx)
    fixture.pause = waitFor
    act("submit:apply")
    assert(fixture.pending, "save did not reach the selected stage")
end
local function assertRevoked()
    assert(not fixture.state.panel and not shows(secret), "revoked draft is still visible")
    local count = #fixture.calls
    if fixture.pending then fixture.pending() end
    fixture.submitContext.store(key, "write", {title="stale"}, function() error("revoked continuation ran") end)
    assert(#fixture.calls == count, "revoked panel dispatched another store operation")
end

-- A panel may bind before the first list scope. The same identity must keep it open.
-- Revoking access makes the draft disappear even if a save reply is outstanding.
start()
act("new_issue")
respond(2, a)
templates(1, a)
assert(shows(secret))
respond(1, a)
assert(shows(secret))
editTitle("draft-save:" .. key)
fixture.sync(nil, "identity changed", true)
assertRevoked()
assert(fixture.records[partition(a)][key].title == secret .. "x", "already dispatched save was not confined to the old partition")
act("new_issue")
respond(3, b)
templates(2, b)
assert(shows("@bob") and not shows(secret), "the new account got the old draft")

-- The first list identity itself can invalidate an already loaded panel. A dispatched save can
-- finish only in the old partition; its callback must not issue any further operations.
start()
act("new_issue")
respond(2, a)
templates(1, a)
editTitle("draft-save:" .. key)
assert(fixture.calls[#fixture.calls].scope == partition(a))
respond(1, b)
assertRevoked()
assert(fixture.records[partition(a)][key].title == secret .. "x")
assert(fixture.records[partition(b)] == nil)

-- Changing repository identity in a template response revokes even before the list check finishes.
-- The stale list response cannot restore the invalid identity or overwrite the new panel.
start()
act("new_issue")
respond(2, a)
templates(1, replaced)
assertRevoked()
assert(#fixture.calls == 0, "template identity mismatch read old records")
act("new_issue")
respond(3, replaced)
templates(2, replaced)
respond(1, a)
assert(fixture.state.panel and shows("@alice") and not shows(secret))
assert(fixture.records[partition(replaced)][key] == nil)

-- A transport or GraphQL failure must not expose the prior account's local
-- draft. A template-specific failure may fall back only after access is confirmed.
for _, allowed in {false, true} do
    start()
    respond(1, a)
    act("new_issue")
    respond(2, a)
    fixture.queries[1](nil, "permission denied")
    assert(not shows(secret) and #fixture.calls == 0, "failed templates opened the old local partition")
    respond(3, if allowed then a else nil)
    if allowed then
        assert(shows(secret) and shows("permission denied"), "verified account lost access to its local draft")
    else
        assertRevoked()
        assert(#fixture.calls == 0)
    end
end
-- Revoke during confirmation's template read, before the identity-bound sender.
-- There is no consumed slot or lock, and the original account can confirm anew.
start()
respond(1, a)
act("new_issue")
respond(2, a)
templates(1, a)
act("submit:resume")
act("submit:preview")
act("submit:confirm", "1")
respond(3, a)
fixture.sync(nil, "identity changed", true)
templates(2, a)
assertRevoked()
assert(#fixture.sends == 0 and not fixture.records[partition(a)]["submit-lock-1"], "revocation consumed an unsent draft")
act("new_issue")
respond(4, a)
templates(3, a)
act("submit:resume")
act("submit:preview")
act("submit:confirm", "1")
respond(5, a)
templates(4, a)
assert(#fixture.sends == 1 and fixture.sends[1].title == secret and fixture.sends[1].slot == 1,
    "original account could not submit the reopened draft")
assert(not shows(secret) and shows("正在核对 GitHub 身份和本地草稿"), "unverified worker failure exposed the previous draft")
respond(6, nil)
assertRevoked()

-- A helper failure is recoverable only after the same identity regains access.
start()
respond(1, a)
act("new_issue")
respond(2, a)
templates(1, a)
act("submit:resume")
act("submit:preview")
act("submit:confirm", "1")
respond(3, a)
templates(2, a)
local before = #fixture.calls
act("submit:title")
assert(not shows(secret) and #fixture.calls == before)
respond(4, a)
templates(3, a)
assert(shows(secret) and shows("继续草稿") and not shows("确认创建一次 Issue") and #fixture.sends == 1)

local function issue(number, title)
    return {id="issue-" .. number, number=number, title=title, state="OPEN"}
end
local function complete(issues)
    return {complete=true, viewer=a.viewer, issues=issues, prs={}}
end

-- Retry with and without a complete mirror. Seeing only PR data on the
-- retry must not roll back the most recently verified Issue title or row.
for _, warm in {false, true} do
    local baseline = if warm then complete({issue(1, "old title")}) else nil
    start(baseline)
    respond(1, a)
    local scan = fixture.scans[1]
    scan.progress("issues", {issue(1, "verified title")})
    scan.done(nil, "offline")
    assert(shows("verified title"))
    act("refresh")
    local retry = fixture.scans[2]
    assert(retry.baseline == baseline and not retry.visible.complete)
    retry.progress("prs", {{id="pr-2", number=2, title="verified PR", state="OPEN"}})
    assert(shows("verified title") and not shows("old title"))
    retry.done(nil, "offline")
    assert(shows("verified title") and not shows("共 1 项"))
end

-- Changes after the initial preview require a fresh preview. On that preview
-- the worker uses the current visibility, not the first panel identity.
local public = table.clone(a)
public.visibility = "PUBLIC"
local old = complete({issue(1, "existing issue")})
start()
respond(1, a)
fixture.scans[1].done(old)
assert(shows("共 1 项"))
act("new_issue")
respond(2, a)
templates(1, a)
act("submit:resume")
act("submit:preview")
act("submit:confirm", "1")
respond(3, public)
assert(#fixture.sends == 0 and shows("旧确认失效"))
act("submit:refresh")
respond(4, public)
templates(2, public)
act("submit:resume")
act("submit:preview")
assert(shows("PUBLIC"))
fixture.pauseSend = true
act("submit:confirm", "2")
respond(5, public)
templates(3, public)
assert(fixture.sends[1].visibility == "PUBLIC" and fixture.sends[1].scope == partition(a))

-- Simulate returning to the list before the worker replies and an in-flight
-- refresh that read its Issue page before creation.
act("close_submit")
act("refresh")
local beforeCreate = fixture.scans[2]
fixture.completeSend("created")
local afterCreate = fixture.scans[3]
assert(afterCreate and not beforeCreate.alive(), "creation did not restart the pre-create scan")
assert(shows("已找到 1 项") and not shows("共 1 项"))
beforeCreate.done(old)
assert(shows("已找到 1 项") and not shows("共 1 项"), "old response marked the list fresh")
afterCreate.progress("issues", {issue(2, "new issue")})
assert(shows("new issue") and shows("已找到 2 项"))
afterCreate.done(complete({issue(2, "new issue"), issue(1, "existing issue")}))
assert(shows("共 2 项") and fixture.state.listing.data.rows[fixture.state.listing.position].number == 1)

-- Manually verifying an ambiguous attempt takes the same refresh path as
-- direct success. Opening the already saved receipt doesn't trigger it again.
start()
respond(1, a)
fixture.scans[1].done(old)
fixture.records[partition(a)]["submit-lock-1"] = {
    kind="attempt", viewerId=a.viewerId, title=secret, time=os.time()-60,
    after="2026-01-01T00:00:00Z", before="2026-01-02T00:00:00Z",
}
act("new_issue")
respond(2, a)
templates(1, a)
assert(shows("结果待核对"))
act("submit:reconcile")
respond(3, a)
local original = {
    __typename="Issue", number=7, id="seven", title=secret, url=a.webUrl.."/issues/7",
    state="OPEN", createdAt="2026-01-01T01:00:00Z", author={id=a.viewerId, login=a.viewer},
}
local function githubResponse(fields)
    fields.id, fields.nameWithOwner = a.repoId, "org/repo"
    return {data={viewer={id=a.viewerId, login=a.viewer}, repository=fields}}
end
fixture.queries[2](githubResponse({issues={pageInfo={hasNextPage=false}, nodes={original}}}))
act("submit:reconcile_choose", "7")
respond(4, a)
fixture.queries[3](githubResponse({issueOrPullRequest=original}))
assert(shows("已关联回执 #7") and #fixture.scans == 2 and #fixture.sends == 0)
fixture.scans[2].done(complete({issue(7, secret), issue(1, "existing issue")}))
act("close_submit")
assert(shows("共 2 项"))
act("new_issue")
respond(5, a)
templates(4, a)
assert(shows("已关联回执 #7") and #fixture.scans == 2)

-- Focused list checks are local and do not trigger network when unchanged.
start()
respond(1, a)
local cached = complete({issue(1, "existing issue")})
cached.resultRevision = "0"
fixture.scans[1].done(cached)
act("return_to_list")
assert(shows("已找到 1 项") and not shows("共 1 项"))
fixture.revisionReply("0")
assert(shows("共 1 项") and #fixture.scans == 1)
act("return_to_list")
fixture.revisionReply("r7")
assert(shows("已找到 1 项") and #fixture.scans == 2)
local updated = complete({issue(7, "second workbench receipt"), issue(1, "existing issue")})
updated.resultRevision = "r7"
fixture.scans[2].done(updated)
assert(shows("共 2 项"))
act("return_to_list")
fixture.revisionReply("r7")
assert(shows("共 2 项") and #fixture.scans == 2)

-- A later focus must be covered even when the earlier local read is still
-- returning. The old reply must not make the exact count visible meanwhile.
start()
respond(1, a)
fixture.scans[1].done(cached)
act("return_to_list")
local firstReply = fixture.revisionReply
act("return_to_list")
act("return_to_list")
assert(fixture.revisionReply == firstReply)
firstReply("0")
local secondReply = fixture.revisionReply
assert(secondReply ~= firstReply and not shows("共 1 项") and #fixture.scans == 1)
secondReply("r7")
assert(not shows("共 1 项") and #fixture.scans == 2)
fixture.scans[2].done(updated)
assert(shows("共 2 项"))

-- Rapid manual refresh requests during a scan coalesce into one follow-up.
-- A subsequent revision change supersedes that scan without a backoff.
start()
respond(1, a)
act("refresh")
assert(block.key(fixture.state, {name="r", text="r"}, cx))
assert(#fixture.scans == 1)
fixture.scans[1].done(cached)
assert(#fixture.scans == 2 and not shows("共 1 项"))
act("return_to_list")
fixture.scans[2].done(nil, nil, nil, true)
assert(#fixture.scans == 3 and not shows("共 1 项"))
fixture.scans[3].done(updated)
assert(#fixture.scans == 3 and shows("共 2 项"))

-- A conflict keeps the pending field in the editor. Explicitly saving it
-- again uses the current version without reverting another panel's title.
start()
respond(1, a)
act("new_issue")
respond(2, a)
templates(1, a)
act("submit:resume")
act("submit:body")
assert(block.key(fixture.state, {name="x", text="local body"}, cx))
local records = fixture.records[partition(a)]
records[key] = {title="other workbench title", form="blank", version="main\ndir\n", fields={body="other body"}}
act("submit:apply")
assert(shows("此字段已保存的值：other body") and shows("local body"))
assert(records[key].fields.body == "other body")
act("submit:apply")
assert(records[key].title == "other workbench title" and records[key].fields.body == "local body")

-- A browser-created Issue invalidates the list only when its external
-- receipt is first saved, not when the same receipt is viewed again.
start()
respond(1, a)
fixture.scans[1].done(cached)
act("new_issue")
respond(2, a)
templates(1, a)
act("submit:external")
assert(block.key(fixture.state, {name="paste", text=original.url}, cx))
act("submit:apply")
respond(3, a)
fixture.queries[2](githubResponse({issueOrPullRequest=original}))
act("submit:bind_external", "7")
assert(shows("已关联回执 #7") and #fixture.scans == 2 and #fixture.sends == 0)
fixture.scans[2].done(updated)
act("close_submit")
assert(shows("共 2 项"))
act("new_issue")
respond(4, a)
templates(3, a)
assert(shows("已关联回执 #7") and #fixture.scans == 2)

-- The external lock may have been saved just before the app stopped.
-- Recovery preserves the receipt on deletion failure and lets users retry
-- without abandoning the cleanup by moving on to another draft.
start()
respond(1, a)
fixture.scans[1].done(updated)
local abandoned = fixture.records[partition(a)]
abandoned["submit-lock-1"] = {kind="external", issue=original}
fixture.removeError = "local storage unavailable"
act("new_issue")
respond(2, a)
templates(1, a)
assert(shows("已关联回执 #7") and shows("本地草稿未清理") and shows("重试清理本地草稿"))
act("submit:next")
assert(abandoned[key] and not abandoned["submit-next-1"] and #fixture.scans == 1)
fixture.removeError = nil
act("submit:cleanup_external")
assert(not abandoned[key] and not shows("重试清理本地草稿") and shows("开始一份新草稿"))
assert(abandoned["submit-lock-1"].issue == original and #fixture.scans == 1 and #fixture.sends == 0)
act("close_submit")
act("new_issue")
respond(3, a)
templates(2, a)
assert(shows("已关联回执 #7") and not shows("本地草稿未清理") and #fixture.scans == 1)

-- An upgrade can find an external receipt behind a persisted successor.
-- Cross only verified links and never delete the successor or another kind's draft.
for _, case in {"external", "attempt", "discard", "remove-error"} do
    start()
    respond(1, a)
    local rows = fixture.records[partition(a)]
    rows["submit-next-1"] = {to=2}
    local external = case == "external" or case == "remove-error"
    rows["submit-lock-1"] = {kind=if external then "external" else case, issue=original}
    local second = table.clone(rows[key])
    second.title = "active successor"
    rows["submit-draft-2"] = second
    fixture.removeError = if case == "remove-error" then "unavailable" else nil
    act("new_issue"); respond(2, a); templates(1, a)
    assert((rows[key] == nil) == (case == "external"))
    assert(rows["submit-draft-2"] == second and shows(second.title) and not shows("已关联回执 #7"))
    if case == "remove-error" then
        assert(shows("历史槽位 1") and shows("草稿清理失败"))
        fixture.removeError = nil
        act("submit:refresh"); respond(3, a); templates(2, a)
        assert(not rows[key] and rows["submit-draft-2"] == second and not shows("草稿清理失败"))
    end
end

local wrongUrl, wrongNumber, noId, noTitle, noState, noTime = table.clone(original), table.clone(original),
    table.clone(original), table.clone(original), table.clone(original), table.clone(original)
wrongUrl.url, wrongNumber.number = "https://github.com/other/repo/issues/7", 8
noId.id, noTitle.title, noState.state, noTime.createdAt = "", nil, "DRAFT", nil
for _, bad in {{}, wrongUrl, wrongNumber, noId, noTitle, noState, noTime} do
    for _, historical in {false, true} do
        start(); respond(1, a)
        local rows = fixture.records[partition(a)]
        rows["submit-lock-1"] = {kind="external", issue=bad}
        local second = table.clone(rows[key])
        second.title = "active successor"
        if historical then rows["submit-next-1"], rows["submit-draft-2"] = {to=2}, second end
        act("new_issue"); respond(2, a); templates(1, a)
        assert(rows[key].title == secret and shows("关联回执无效") and not shows("已关联回执 #"))
        assert(not historical or (rows["submit-draft-2"] == second and shows(second.title)))
        for _, call in fixture.calls do assert(call.op ~= "remove") end
    end
end

-- Both destructive confirmations must fail if the approved draft changed.
-- That includes linking from a panel which originally had no draft.
for _, scenario in {"discard", "external", "external-no-draft"} do
    start()
    respond(1, a)
    fixture.scans[1].done(cached)
    local records = fixture.records[partition(a)]
    if scenario == "external-no-draft" then records[key] = nil end
    act("new_issue")
    respond(2, a)
    templates(1, a)
    if scenario == "discard" then
        act("submit:discard_ask")
        assert(shows("将丢弃：" .. secret))
    else
        act("submit:external")
        assert(block.key(fixture.state, {name="paste", text=original.url}, cx))
        act("submit:apply")
        respond(3, a)
        fixture.queries[2](githubResponse({issueOrPullRequest=original}))
        assert(shows("已验证原件 #7"))
    end
    local newer = {title="other workbench draft", form="blank", version="main\ndir\n", fields={body="private body"}}
    records[key] = newer
    local discarded = scenario == "discard"
    act(if discarded then "submit:discard" else "submit:bind_external", if discarded then nil else "7")
    assert(records[key] == newer and not records["submit-lock-1"] and #fixture.scans == 1)
    assert(shows(if discarded then "未丢弃" else "未关联原件"))
    respond(if discarded then 3 else 4, a)
    templates(if discarded then 2 else 3, a)
    assert(shows(newer.title) and not shows("已验证原件 #7") and not shows("确认丢弃草稿"))
    act(if discarded then "submit:discard" else "submit:bind_external", "7")
    assert(records[key] == newer and not records["submit-lock-1"], "old confirmation remained actionable")
    if discarded then
        act("submit:discard_ask")
        act("submit:discard")
        assert(not records[key] and records["submit-lock-1"].kind == "discard")
        assert(records["submit-next-1"].to == 2 and #fixture.scans == 1)
    end
end

-- Focus while an old cache probe is outstanding: don't confirm counts
-- until a local check covering that focus returns. A second focus while
-- the check runs can see an even later receipt.
for _, revised in {false, true} do
    start()
    fixture.pauseCache = true
    respond(1, a)
    local warm = table.clone(cached)
    warm.checkedEpoch = os.time()
    act("return_to_list")
    fixture.cacheReply(warm)
    assert(shows("已找到 1 项") and not shows("共 1 项") and #fixture.scans == 0)
    if revised then act("return_to_list") end
    local firstCheck = fixture.revisionReply
    firstCheck("0")
    if revised then
        assert(fixture.revisionReply ~= firstCheck and not shows("共 1 项") and #fixture.scans == 0)
        fixture.revisionReply("r7")
        assert(#fixture.scans == 1 and not shows("共 1 项"))
        fixture.scans[1].done(updated)
        assert(shows("共 2 项"))
    else
        assert(shows("共 1 项") and #fixture.scans == 0)
    end
end

print("Issue draft identity, approved visibility, failed sync, and post-create refresh passed.")
LUAU
} > "$root/test.luau"
"${LUAU:-luau}" "$root/test.luau"
