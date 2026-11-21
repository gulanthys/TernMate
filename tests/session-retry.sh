#!/bin/sh
# Run with LUAU=/path/to/luau sh tests/session-retry.sh.
set -eu
src=$(dirname "$0")/..
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-retry-test.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

mkdir "$tmp/empty" "$tmp/zero" "$tmp/blank" "$tmp/malformed" "$tmp/hidden" "$tmp/nonregular"
: > "$tmp/zero/omp.jsonl"
printf ' \n' > "$tmp/blank/omp.jsonl"
printf '%s\n' 'not a session header' > "$tmp/malformed/omp.jsonl"
: > "$tmp/hidden/.omp.jsonl"
ln -s "$tmp/missing-file" "$tmp/nonregular/omp.jsonl"
ln -s "$tmp/empty" "$tmp/replaced"
probe() {
    status=0
    /bin/sh "$src/session-setup.sh" session-empty "$tmp/$1" 2> "$tmp/probe.err" || status=$?
    if [ "$status" != "$2" ]; then
        printf '%s\n' "session-empty $1: expected $2, got $status" >&2
        cat "$tmp/probe.err" >&2
        exit 1
    fi
    printf '%s = %s,\n' "$1" "$status"
}
{
    printf '%s\n' 'local directoryStatus = {'
    probe empty 0
    probe zero 3
    probe blank 3
    probe malformed 3
    probe hidden 3
    probe nonregular 3
    probe missing 1
    probe replaced 1
    printf '%s\n' '}'
    cat <<'LUAU'
local head, base = string.rep('a', 40), string.rep('b', 40)
local repo = { host = 'github.test', owner = 'owner', name = 'repo' }
local identity = { repoId = 'repo-id', viewerId = 'viewer-id' }
local revision = { head = head, baseSHA = base, baseRef = 'main' }
local request = {
	repo = repo, identity = identity, checkout = '/checkout', kind = 'pr', number = 7, pane = 1, review = true,
}
local data, program, tool = '/data', '/bin/omp', '/bin/tern'
local task = data .. '/task-sessions-v2/task.fixture'
local file = task .. '/session/omp.jsonl'
local s
local function copy(value)
	if type(value) ~= 'table' then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = copy(v) end
	return out
end
local decoded = {}
local function encode(value)
	if #value == 0 then return '{}' end
	return '["' .. table.concat(value, '","') .. '"]'
end
local tern = {
	plugin = { dir = '/plugin', id = 'ternmate', data = data },
	runtime = { os = 'linux' },
	json = { encode = encode, decode = function(key) return copy(assert(decoded[key], key)) end },
	kv = {
		get = function(key) return copy(s.indices[key]) end,
		set = function(key, value) s.indices[key] = copy(value) end,
	},
	pane = { list = function() return { { pane = 1 } } end },
	timer = function(_, cb) table.insert(s.timers, cb) end,
}
local os = { time = function() return s.clock end }
local modules = {
	['./maintenance_data'] = { identity = function(_, cb) cb(identity) end },
	['./materials'] = {
		revision = function(_, _, _, _, cb) cb(revision) end,
		collect = function(_, _, _, _, _, _, _, cb) cb({ identity = identity, head = head }) end,
	},
}
local function require(name) return assert(modules[name], name) end
modules['./runtime'] = (function()
LUAU
    cat "$src/runtime.luau"
    printf '%s\n' 'end)()' 'local sessions = (function()'
    cat "$src/sessions.luau"
    printf '%s\n' 'end)()'
    cat <<'LUAU'
local function result(status, stdout, timedOut)
	return { status = status, stdout = stdout or '', stderr = '', timed_out = timedOut or false }
end
local function json(value, timedOut)
	local id = tostring(value)
	decoded[id] = value
	return result(0, id, timedOut)
end
local source = { pane = 1, program = 'ternmate.workbench', cwd = '/checkout' }
local function view()
	local panes = { copy(source) }
	local tabs = { { blocks = { { id = 1, live = true, program = source.program } } } }
	for _, pane in ipairs(s.panes) do
		table.insert(panes, copy(pane))
		table.insert(tabs, { blocks = { {
			id = pane.pane, program = pane.program, args = copy(pane.args), live = not pane.detached,
			keep_open = true, exited = pane.exited,
		} } })
	end
	return { panes = panes, clients = { { kind = 'gui', window = '2' } }, sessions = { { id = 6, tabs = tabs } } }
end
local function exec(argv, _, cb)
	local op = argv[2]
	if argv[1] == '/bin/sh' then
		assert(argv[2] == '/plugin/session-setup.sh')
		op = argv[3]
		if op == 'tern' then cb(result(0, tool .. '\n'))
		elseif op == 'source' then cb(result(0, '/checkout\n' .. data .. '\n'))
		elseif op == 'omp' then cb(result(0, program .. '\n'))
		elseif op == 'allocate' then cb(result(0, task .. '\n'))
		elseif op == 'material' or op == 'prepare' or op == 'pr-prompt' then cb(result(0))
		elseif op == 'check-review' then cb(result(0, head .. '\nclean\n'))
		elseif op == 'discover' then cb(result(0, if s.directory == 'malformed' or s.directory == 'blank' or s.file then file .. '\n' else ''))
		elseif op == 'file' then
			assert(argv[5] == file)
			local header = if s.file then json({ type = 'session', cwd = task }).stdout else 'malformed'
			cb(result(0, header .. '\n'))
		elseif op == 'session-empty' then
			assert(argv[4] == task .. '/session')
			cb(result(assert(directoryStatus[s.directory])))
		else error('unexpected helper operation: ' .. op) end
		return
	end
	assert(argv[1] == tool)
	if op == 'inspect' then
		cb(json(view()))
	elseif op == 'new' then
		assert(argv[3] == 'tab' and argv[4] == '6' and argv[6] == '--window=2' and argv[9] == '--keep-open')
		s.launches += 1
		local id = 8589934593 + s.launches
		local outcome = assert(s.outcomes[s.launches])
		local args = { table.unpack(argv, 12) }
		assert(args[1] == '--cwd=' .. task and args[2] == '--session-dir=' .. task .. '/session')
		if s.file then assert(args[#args] == '--resume=' .. file) end
		if outcome.directory then s.directory = outcome.directory end
		if outcome.pane then
			local pane = { pane = id, cwd = task, program = '/bin/zsh', args = { '-c', table.concat(argv, ' ', 11) } }
			if outcome.direct then pane.program, pane.args = program, args end
			pane.detached = outcome.detached
			if outcome.pane == 'exit' then pane.exited = 1 end
			if outcome.report then pane.omp_session_file = outcome.report end
			if outcome.pane == 'running' then s.processes[id] = { argv = { table.unpack(argv, 11) }, cwd = task } end
			table.insert(s.panes, pane)
		end
		if outcome.error then cb(result(1)); return end
		cb(json({ session = outcome.session or 6, tab = id - 1, block = outcome.block or id }, outcome.timeout))
	elseif op == 'process' then
		local id = assert(tonumber(argv[3]))
		cb(json({ pane = id, child = s.processes[id] }))
	elseif op == 'focus' or op == 'rename' then
		local id = assert(tonumber(argv[3]))
		assert(s.processes[id], 'no focus or rename for a failed tab')
		table.insert(s.touched, id)
		cb(result(0))
	else error('unexpected Tern operation: ' .. op) end
end
local function reset(...)
	s = {
		outcomes = { ... }, launches = 0, directory = 'empty', clock = 1000,
		indices = {}, panes = {}, processes = {}, touched = {}, timers = {},
	}
end
local function activate()
	local done, message, problem = 0, nil, nil
	sessions.open(exec, request, function() end, function(m, err)
		done += 1
		message, problem = m, err
	end)
	while done == 0 and #s.timers > 0 do table.remove(s.timers, 1)() end
	assert(done == 1 and (message or problem))
	return message, problem
end
local function index()
	local _, value = next(s.indices)
	return assert(value)
end
local function record()
	local _, value = next(index().records)
	return assert(value)
end
local function waitOutLaunch()
	s.clock += 60
end
local function phase(expected)
	assert(record().phase == expected, record().phase .. ' ~= ' .. expected)
end

-- Each independently confirmed pre-conversation exit permits a manual retry.
reset({ pane = 'exit' }, { pane = 'exit' }, { pane = 'running' })
local _, problem = activate()
assert(problem:find('可再次打开', 1, true))
phase('retryable')
assert(s.launches == 1 and #s.touched == 0)
activate(); phase('retryable')
assert(s.launches == 2 and #s.touched == 0)
assert(activate()); phase('opened')
assert(record().pane == 8589934596 and #s.touched == 2 and #s.panes == 3)
assert(s.panes[1].exited == 1 and s.panes[2].exited == 1)
s.panes[3].exited = 1
activate(); phase('opened')
assert(s.launches == 3, 'never replace an opened conversation')

-- A prior exit cannot certify a subsequent attempt that never appears.
reset({ pane = 'exit' }, {}, { pane = 'running' })
activate(); phase('retryable')
activate(); phase('launching')
waitOutLaunch(); activate(); phase('launching')
assert(s.launches == 2 and #s.touched == 0)

-- Even a receipt for a historically present pane cannot identify the new tab.
reset({ pane = 'exit' }, { block = 8589934594 })
activate(); phase('retryable')
activate(); phase('launching')
assert(record().launchAttempt.pane == nil)

-- Empty, malformed, hidden and non-regular directory entries all bar a retry.
for _, state in ipairs({ 'zero', 'blank', 'malformed', 'hidden', 'nonregular' }) do
	reset({ pane = 'exit', directory = state })
	activate(); phase('launching')
	waitOutLaunch(); activate(); phase('launching')
	s.directory = 'empty'
	activate(); phase('launching')
	assert(s.launches == 1 and #s.touched == 0)
end

-- Recheck the directory at the next activation before making a new tab.
reset({ pane = 'exit' }, { pane = 'running' })
activate(); phase('retryable')
s.directory = 'zero'
activate(); phase('retryable')
assert(s.launches == 1)

for _, outcome in ipairs({
	{ pane = 'exit', timeout = true },
	{ pane = 'exit', error = true },
	{ pane = 'exit', session = 7 },
	{ pane = 'exit', detached = true },
	{ pane = 'exit', report = '/outside/session.jsonl' },
	{ pane = 'exit', directory = 'missing' },
}) do
	reset(outcome)
	activate(); phase('launching')
	waitOutLaunch(); activate(); phase('launching')
	assert(s.launches == 1 and #s.touched == 0)
end

-- A receipt can establish that an initially unverified pane has since exited.
reset({ pane = 'unverified' }, { pane = 'running' })
activate(); phase('launching')
s.panes[1].exited = 1
waitOutLaunch(); assert(activate()); phase('opened')
assert(s.launches == 2 and record().pane == 8589934595)

-- Legacy shell-wrapper candidates without launch proof remain protected.
reset({ pane = 'exit', timeout = true })
activate(); phase('launching')
record().launchAttempt = nil
waitOutLaunch(); activate(); phase('launching')
assert(s.launches == 1)
record().phase, record().launchingUntil = 'prepared', nil
activate(); phase('prepared')
assert(s.launches == 1, 'a legacy prepared state does not authorize ignoring an old candidate')

-- A unique, exact legacy invocation can be recovered without guessing shell text.
reset({ pane = 'exit', timeout = true, direct = true }, { pane = 'running' })
activate(); phase('launching')
record().launchAttempt = nil
waitOutLaunch(); assert(activate()); phase('opened')
assert(s.launches == 2 and record().pane == 8589934595)

-- A failure during an exact resume must not unlock a fresh launch.
reset({ pane = 'exit' }, { pane = 'exit' })
activate(); phase('retryable')
s.file = true
activate(); phase('launching')
assert(record().file == file and record().launchAttempt == nil)
s.file = false
waitOutLaunch(); activate(); phase('launching')
assert(s.launches == 2)
print('Session retry lifecycle and physical emptiness checks passed.')
LUAU
} > "$tmp/retry.luau"
"${LUAU:-luau}" "$tmp/retry.luau"
