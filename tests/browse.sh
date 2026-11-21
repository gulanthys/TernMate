#!/bin/sh
# Run with LUAU=/path/to/luau sh tests/browse.sh.
set -eu
script=$(mktemp "${TMPDIR:-/tmp}/ternmate-browse.XXXXXXXX")
trap 'rm -f "$script"' EXIT
trap 'exit 1' HUP INT TERM
{
cat <<'LUAU'
local block
local ui = setmetatable({}, {__index = function() return function(...) return {...} end end})
local tern = {now = function() return 300001 end, ui = ui, block = {define = function(_, def) block = def end}}
local opened = {}
local function require(name)
	if name == './sessions' then return {open = function(_, request) table.insert(opened, request.number) end} end
	if name == './runtime' then return {repoKey = function() return 'repo' end} end
	return {}
end
do
LUAU
cat "$(dirname "$0")/../host.luau"
cat <<'LUAU'
end
local cx = {pane = 1, rows = 30}
local scope = {snapshot = {complete = true}, checked = tern.now(), identity = {}, prsOpen = 2}
local rows = {{number = 1, title = 'one', state = 'OPEN', ci = 'none'}, {number = 2, title = 'two', state = 'OPEN', ci = 'none'}}
local list = {data = {rows = rows, uncertain = 0}, position = 2}
local state = {repo = {host = 'github.test', owner = 'org', name = 'repo'}, repos = {}, generation = 1,
	saved = {kind = 'pr', checkout = '/repo', filtersByRepo = {}}, read = scope, listing = list}
local function contains(node, value)
	if type(node) ~= 'table' then return node == value end
	for _, child in node do if contains(child, value) then return true end end
	return false
end
local function count(label, exact)
	local page = block.view(state, cx).dock
	assert(contains(page, label) and contains(page, '共 2 项') == exact, label)
end
count('共 2 项', true)
for _, entry in {{'loading', true}, {'error', 'offline'}, {'checked', 0}} do
	local before = scope[entry[1]]; scope[entry[1]] = entry[2]
	count('已找到 2 项', false); scope[entry[1]] = before
end
list.data.uncertain = 1; count('已找到 2 项', false); list.data.uncertain = 0
scope.snapshot.complete = false; count('已找到 2 项', false); scope.snapshot.complete = true
local function act(name, serial) block.event(state, {ev = 'action', act = name, value = tostring(serial)}, cx) end
for _, how in {'button', 'escape'} do
	state.confirm = {serial = 12, number = 1, notice = {current = {head = string.rep('a', 40)}}}
	act('cancel_version', 11); assert(state.confirm, 'stale cancel dismissed a newer notice')
	if how == 'button' then act('cancel_version', 12) else assert(block.key(state, {name = 'escape'}, cx)) end
	assert(not state.confirm and list.position == 2)
	act('new_version', 12); assert(#opened == 0, 'dismissed version still opened')
end
block.key(state, {name = 'enter'}, cx); assert(opened[1] == 2 and #opened == 1, 'cancel lost the selected PR')
state.opening = nil
for n = 3, 23 do rows[n] = {number = n, title = tostring(n), state = 'OPEN', ci = 'none'} end
block.key(state, {name = 'left'}, cx); assert(list.position == 2, 'first page must not wrap or reset')
block.key(state, {name = 'right'}, cx); assert(list.position == 21, 'right should select the next page’s first row')
block.key(state, {name = 'down'}, cx); assert(list.position == 22, 'down should still select one row')
block.key(state, {name = 'right'}, cx); assert(list.position == 22, 'last page must not wrap or reset')
act('page', 1); assert(list.position == 1, 'pager click should return to the first row')
act('page', 2); block.key(state, {name = 'left'}, cx); assert(list.position == 1, 'left should match the pager click')
state.edit = {key = 'title', text = 'ab', caret = 3}
block.key(state, {name = 'left'}, cx); assert(state.edit.caret == 2 and list.position == 1, 'editing must keep cursor navigation')
print('Browse coverage, version cancellation, and keyboard pagination passed.')
LUAU
} > "$script"
"${LUAU:-luau}" "$script"
