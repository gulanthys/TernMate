#!/bin/sh
# Run with LUAU=/path/to/luau sh tests/issue-badges.sh.
set -eu
root=$(dirname "$0")/..
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-badge-test.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

# Luau CLI requires files in separate environments. Inject the SDK fixture
# into the real module's environment without changing production code.
{
    cat <<'LUAU'
local panes = {}
local records = {}
local key = 'session-v2:["github.test","repo-id","viewer-id","issue","7","/checkout"]'
local index = { records = records }
local tern = {
	pane = { list = function() return panes end },
	json = { encode = function(parts) return '["' .. table.concat(parts, '","') .. '"]' end },
	kv = { get = function(k) return if k == key then index else nil end },
}
local function require(name)
	assert(name == './runtime' or name == './materials' or name == './maintenance_data', name)
	return {}
end
local module = assert(loadstring([====[
LUAU
    cat "$root/sessions.luau"
    cat <<'LUAU'
]====], 'sessions.luau'))
local sessions = setfenv(module, setmetatable({ tern = tern, require = require }, { __index = getfenv() }))()

local repo = { host = 'github.test', owner = 'owner', name = 'repo' }
local identity = { repoId = 'repo-id', viewerId = 'viewer-id' }
local badge = '处理中 · 本机 omp 面板已打开'
local parent = '/plugin-data/ternmate/task-sessions-v2/'
local old, new = string.rep('a', 40), string.rep('b', 40)
local oldDir, newDir = parent .. 'task.old', parent .. 'task.new'
local function record(dir, pane, phase)
	return { phase = phase, pane = pane, dir = dir, program = '/bin/omp', subject = 'owner/repo issue #7' }
end
local function pane(id, cwd)
	return { pane = id, cwd = cwd, program = '/bin/zsh', title = 'Shell wrapper', busy = false }
end
local function currentBadge()
	return sessions.issueBadges(repo, identity, '/checkout')(7)
end

records[old], records[new] = record(oldDir, 42, 'opened'), record(newDir, 45, 'opened')
index.latest = new
panes = { pane(42, oldDir .. '/worktree') }
assert(currentBadge() == badge, 'a running older worktree counts after the latest pane closes')
assert(sessions.issueBadges(repo, identity, '/another-checkout')(7) == '', 'other checkout')
assert(sessions.issueBadges(repo, { repoId = 'other-repo', viewerId = 'viewer-id' }, '/checkout')(7) == '', 'other repository')
assert(sessions.issueBadges(repo, { repoId = 'repo-id', viewerId = 'other-viewer' }, '/checkout')(7) == '', 'other account')
assert(sessions.issueBadges(repo, identity, '/checkout')(8) == '', 'other issue')
index.latest = nil
assert(currentBadge() == badge, 'a missing latest pointer does not hide a retained pane')

index.latest = new
panes = { pane(45, newDir) }
assert(currentBadge() == badge, 'the launch directory counts before the worktree cwd is reported')
records[new].phase = 'launching'
assert(currentBadge() == '', 'a launch not marked opened does not count')
records[new].phase = 'opened'
panes = { pane(45, oldDir .. '/worktree'), pane(42, '/unrelated') }
assert(currentBadge() == '', 'matching pane IDs in the wrong directory do not count')
panes = { pane(46, newDir .. '/worktree'), pane(45, nil) }
assert(currentBadge() == '', 'a missing cwd or an unrecorded pane ID does not count')
panes = {}
assert(currentBadge() == '', 'no open panes')
print('Issue badge version and pane matching passed.')
LUAU
} > "$tmp/badges.luau"

"${LUAU:-luau}" "$tmp/badges.luau"
