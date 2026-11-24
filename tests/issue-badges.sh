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
	plugin = { dir = '/plugin', data = '/plugin-data/ternmate' },
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
local badge = 'running'
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
assert(currentBadge() == 'recorded', 'a pending launch must not hide a retained conversation')
records[new].phase = 'opened'
panes = { pane(45, oldDir .. '/worktree'), pane(42, '/unrelated') }
assert(currentBadge() == 'recorded', 'a reused pane ID does not establish that a conversation is running')
panes = { pane(46, newDir .. '/worktree'), pane(45, nil) }
assert(currentBadge() == 'recorded', 'a missing cwd or an unrecorded pane ID does not count as running')
panes = {}
assert(currentBadge() == 'recorded', 'a closed conversation still has a record')
table.clear(records)
for _, phase in { 'prepared', 'retryable', 'launching' } do
	records[new] = record(newDir, 45, phase)
	assert(currentBadge() == phase)
end
table.clear(records)
assert(currentBadge() == '', 'no activity must not imply a repair or an existing session')
print('Issue badge version and pane matching passed.')

records[new] = record(newDir, 45, 'opened')
local cleaned
sessions.autoCleanup(function(argv, _, reply)
	local output
	if argv[3] == 'source' then
		output = '/checkout\n/plugin-data/ternmate\n'
	elseif argv[3] == 'workspace-list' then
		output = 'task.unrelated\nend\n'
	else
		error('removed workspaces must be skipped before remote or pane checks: ' .. table.concat(argv, ' '))
	end
	reply({ status = 0, stdout = output, timed_out = false })
end, { repo = repo, identity = identity, checkout = '/checkout' }, {
	issues = {{ state = 'CLOSED', number = 7 }}, prs = {},
}, function() return true end, function(count) cleaned = count end)
assert(cleaned == 0)
print('An archived task index does not trigger cleanup checks.')

local facts
sessions.issueWork(function(argv, _, reply)
	assert(argv[3] == 'issue-work' and argv[6] == newDir)
	reply({status = 0, timed_out = false, stdout = 'commits clean split\n'})
end, repo, identity, '/checkout', 7, function(value) facts = value end)
assert(facts and facts.commits and facts.clean and facts.split and not facts.unknown)
print('Issue evidence retains the split-workspace marker separately from original worktree cleanliness.')
LUAU
} > "$tmp/badges.luau"

"${LUAU:-luau}" "$tmp/badges.luau"

# Exercise real linked worktrees without loading the user's Git configuration.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
tmp=$(cd "$tmp" && pwd -P)
checkout=$tmp/checkout
data=$tmp/data
task=$data/task-sessions-v2/task.fixture
mkdir -p "$checkout" "$task"
git -C "$checkout" init -q --template=
printf 'base\n' > "$checkout/sample.txt"
printf '*.txt filter=sideeffect\n' > "$checkout/.gitattributes"
git -C "$checkout" add sample.txt .gitattributes
git -C "$checkout" -c user.name=Fixture -c user.email=fixture@example.test commit -qm baseline
base=$(git -C "$checkout" rev-parse HEAD)
/bin/sh "$root/session-setup.sh" prepare-issue "$task" "$checkout" 7 "$base" 2>/dev/null
[ "$(/bin/sh "$root/session-setup.sh" workspace-list "$data")" = "$(printf 'task.fixture\nend')" ]
probe_work() {
    /bin/sh "$root/session-setup.sh" issue-work "$checkout" "$data" "$task" "$base"
}
[ "$(probe_work)" = 'initial clean' ]
printf 'tracked\n' >> "$task/worktree/sample.txt"
[ "$(probe_work)" = 'initial dirty' ]
git -C "$task/worktree" add sample.txt
git -C "$task/worktree" -c user.name=Fixture -c user.email=fixture@example.test commit -qm implementation
printf 'untracked\n' > "$task/worktree/new.txt"
[ "$(probe_work)" = 'commits dirty' ]
git -C "$checkout" config filter.sideeffect.clean "touch '$tmp/filter-ran'; cat"
printf 'wanted change\n' >> "$task/worktree/sample.txt"
[ "$(probe_work)" = 'commits unknown' ]
[ ! -e "$tmp/filter-ran" ]
[ "$(/bin/sh "$root/session-setup.sh" issue-work "$checkout" "$data" "$data/task-sessions-v2/task.missing" "$base")" = 'unavailable unknown' ]
[ "$(git -C "$checkout" rev-parse HEAD)" = "$base" ]
printf '%s\n' 'Issue worktree status distinguishes commits, pending changes, and unsafe or missing evidence.'

git -C "$checkout" config --unset filter.sideeffect.clean
git -C "$task/worktree" restore sample.txt
rm "$task/worktree/new.txt"
published=$(git -C "$task/worktree" rev-parse HEAD)
code=0
/bin/sh "$root/session-setup.sh" cleanup-issue "$data" "$task" "$checkout" "$base" 7 || code=$?
[ "$code" -eq 3 ] && [ -d "$task/worktree" ]
scope=6769746875622e74657374-72-76
TERNMATE_CLEANUP_HISTORY=$scope /bin/sh "$root/session-setup.sh" cleanup-issue "$data" "$task" "$checkout" "$base" 7 "$published"
[ ! -e "$task/worktree" ]
[ "$(/bin/sh "$root/session-setup.sh" workspace-list "$data")" = end ]
! git -C "$checkout" show-ref --verify --quiet refs/heads/ternmate/issue-7-fixture
[ "$(git -C "$checkout" rev-parse refs/ternmate/archived/issue-7-fixture)" = "$published" ]
[ "$(probe_work)" = 'archived archived' ]
/bin/sh "$root/session-setup.sh" restore-issue "$data" "$task" "$checkout" "$base" 7
[ "$(git -C "$task/worktree" rev-parse HEAD)" = "$published" ]
[ "$(git -C "$checkout" rev-parse HEAD)" = "$base" ]
history=$(/bin/sh "$root/session-setup.sh" cleanup-history "$data" "$scope")
[ "$(printf '%s\n' "$history" | cut -f2-)" = "$(printf 'issue\t7\tternmate/issue-7-fixture\t%s\nend' "$published")" ]
printf '%s\n' 'Issue automatic cleanup protects unpublished commits and restores exactly the archived tip.'

sub=$tmp/submodule
git init -q --template= "$sub"
printf 'base\n' > "$sub/file"
git -C "$sub" add file
git -C "$sub" -c user.name=Fixture -c user.email=fixture@example.test commit -qm baseline
printf 'file filter=fixture\n' > "$sub/.gitattributes"
git -C "$sub" add .gitattributes
git -C "$sub" -c user.name=Fixture -c user.email=fixture@example.test commit -qm attributes
git -C "$task/worktree" -c protocol.file.allow=always submodule add -q "$sub" submodule
git -C "$task/worktree" -c user.name=Fixture -c user.email=fixture@example.test commit -qm submodule
git -C "$task/worktree/submodule" config filter.fixture.clean "touch '$tmp/submodule-filter-ran'; cat"
printf 'dirty\n' >> "$task/worktree/submodule/file"
[ "$(probe_work)" = 'commits unchecked' ]
tip=$(git -C "$task/worktree" rev-parse HEAD)
code=0
/bin/sh "$root/session-setup.sh" cleanup-issue "$data" "$task" "$checkout" "$tip" 7 || code=$?
[ "$code" -eq 7 ] && [ -d "$task/worktree" ] && [ ! -e "$tmp/submodule-filter-ran" ]
printf '%s\n' 'Dirty submodule contents are not represented as a clean Issue worktree.'
