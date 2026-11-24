#!/bin/sh
# Run with LUAU=/path/to/luau sh tests/refresh-sync.sh.
set -eu
src=$(dirname "$0")/..
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-refresh-test.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
{
    cat <<'LUAU'
local wire, serial = {}, 0
local function encode(value)
	serial += 1
	local key = tostring(serial)
	wire[key] = value
	return key
end
local function decode(key)
	local value = assert(wire[key], 'unknown wire message: ' .. key)
	wire[key] = nil
	return value
end
local tern = { plugin = { dir = '/plugin', data = '/data' }, json = { encode = encode, null = {} } }
local runtime = { decode = decode, trim = function(value) return value end,
	failure = function(raw, err) return err or raw.stderr end }
local function require(name) assert(name == './runtime', name); return runtime end
local data = (function()
LUAU
    cat "$src/maintenance_data.luau"
    printf '%s\n' 'end)()'
    cat <<'LUAU'
local repo = { host = 'github.test', owner = 'owner', name = 'repo' }
local identity = { repoId = 'repo-id', viewerId = 'viewer-id', viewer = 'viewer', webUrl = 'https://github.test/owner/repo' }
local last = 120 -- More than one GitHub connection page without fixing its requested size.
local kinds = { issues = 'issues', prs = 'pullRequests' }
local missing = 'issues:removed'
local function connection(nodes, cursor, total)
	return { nodes = nodes, totalCount = total or #nodes, pageInfo = { hasNextPage = cursor ~= nil, endCursor = cursor } }
end
local linkedIssue = 50
local function linked(number, state, cross)
	return { id = 'linked:' .. number, number = number, state = state, isDraft = false,
		repository = if cross then {id = 'another-repo', nameWithOwner = 'other/repo'} else {id = identity.repoId, nameWithOwner = 'owner/repo'} }
end
local function item(kind, number, old, detail)
	local changed = number == 1 or number == last
	local prefix = if old or not changed then 'prior ' else 'remote '
	local row = { id = kind .. ':' .. number, number = number, updatedAt = prefix .. number, state = 'CLOSED' }
	if kind == 'issues' and number == linkedIssue then row.state = 'OPEN' end
	if kind == 'prs' then
		row.headRefOid, row.baseRefName, row.isDraft = 'head', 'main', false
		row.bodyHTML = ""
		if old then row.bodyIssueReferences = {nodes={}, complete=true}; row.bodyHTML = nil end
	end
	if detail then
		row.title, row.url = prefix .. row.id, identity.webUrl .. '/' .. kind .. '/' .. number
		local label = if old then 'prior' else 'first'
		row.labels = if number == last then connection({ { id = label, name = label } },
			if old then nil else 'labels', if old then 1 else 2) else connection({})
		if kind == 'issues' then
			row.assignees = connection({})
			row.closedByPullRequestsReferences = if number == linkedIssue then connection({ linked(7, if old then 'OPEN' else 'MERGED', true) })
				elseif number == last then connection({ linked(8, 'OPEN') }, if old then nil else 'links', if old then 1 else 2)
				else connection({})
		else
			row.isCrossRepository, row.mergeable, row.commits = false, 'MERGEABLE', { nodes = {} }
			row.closingIssuesReferences, row.reviewThreads = connection({}), connection({})
			row.latestReviews, row.reviewRequests = connection({}), connection({})
		end
	end
	return row
end
local function freeze(value)
	for _, child in value do if type(child) == 'table' then freeze(child) end end
	table.freeze(value)
end
local function byId(items, id)
	for _, row in items do if row.id == id then return row end end
	return nil
end

local function scenario(stillExists, revised)
	local epoch = os.time() - 60
	local previous = { complete = true, host = repo.host, repoId = identity.repoId, repoUrl = identity.webUrl,
		viewerId = identity.viewerId, viewer = identity.viewer, observedAt = '2026-01-01T00:00:00Z',
		checkedEpoch = epoch, reconciledEpoch = epoch, issues = {}, prs = {} }
	local visible, scan = {}, {}
	for kind in kinds do
		visible[kind], scan[kind] = {}, {}
		for number = last, 1, -1 do
			local row = item(kind, number, true, true)
			table.insert(previous[kind], row)
			visible[kind][row.id] = row
		end
	end
	local obsolete = item('issues', last + 1, true, true)
	obsolete.id = missing
	table.insert(previous.issues, obsolete)
	visible.issues[missing] = obsolete
	-- A failed earlier scan showed a different title for a historical
	-- Issue. Its inventory fields now match the baseline, but detail
	-- must be rechecked before replacing the displayed version.
	local lastVisible = { issues = table.clone(previous.issues), prs = previous.prs }
	local reverted = 'issues:2'
	local priorPreview = table.clone(byId(lastVisible.issues, reverted))
	priorPreview.title = 'title from failed scan'
	lastVisible.issues[last - 1] = priorPreview
	visible.issues[reverted] = priorPreview
	freeze(previous) -- Partial upserts must not mutate any part of the complete mirror.

	local pending, writes, completions = {}, 0, 0
	local result, failure, saved, confirmedMissing, revisionChanged
	local function answer(query, vars)
		assert(vars.owner == repo.owner and vars.name == repo.name)
		local payload = { viewer = { id = identity.viewerId, login = identity.viewer },
			repository = { id = identity.repoId, nameWithOwner = repo.owner .. '/' .. repo.name } }
		local detail = query:match('%stitle%s+url%s') ~= nil
		if vars.id then
			local kind, number = vars.id:match('^(%a+):(%d+)$')
			assert(tonumber(number) == last)
			assert(visible[kind][vars.id].title == 'prior ' .. vars.id, 'published before nested verification')
			payload.node = item(kind, last, false, false)
			payload.node.repository = { id = identity.repoId }
			if vars.cursor == 'links' then
				assert(kind == 'issues' and query:find('includeClosedPrs:true', 1, true))
				payload.node.closedByPullRequestsReferences = connection({ linked(9, 'CLOSED') }, nil, 2)
			else
				assert(vars.cursor == 'labels' and query:find('labels', 1, true))
				scan[kind].expanded = true
				payload.node.labels = connection({ { id = 'second', name = 'second' } }, nil, 2)
			end
		elseif vars.ids then
			payload.nodes = {}
			for _, id in vars.ids do
				if id == missing then
					assert(visible.issues[missing] == obsolete and writes == 0)
					confirmedMissing = true
					table.insert(payload.nodes, if stillExists then { id = missing, repository = { id = identity.repoId } } else tern.json.null)
				else
					local kind, number = id:match('^(%a+):(%d+)$')
					local row = item(kind, assert(tonumber(number), id), false, detail or query:find('closedByPullRequestsReferences', 1, true) ~= nil)
					row.repository = { id = identity.repoId }
					table.insert(payload.nodes, row)
				end
			end
		else
			local name, args = query:match('(issues)(%b())')
			if not name then name, args = query:match('(pullRequests)(%b())') end
			assert(name, 'expected a repository connection: ' .. query)
			local kind = if name == kinds.issues then 'issues' else 'prs'
			local pageSize = assert(tonumber(args:match('first:%s*(%d+)')), args)
			assert(args:find('field:%s*CREATED_AT') and args:find('direction:%s*DESC'), args)
			local state = scan[kind]
			if vars.cursor then
				state.continued = true
			else
				assert(detail and not state.started, 'start with the latest detailed ' .. kind)
				state.started = true
			end
			local offset = if vars.cursor then assert(tonumber(vars.cursor)) else 0
			local count = math.min(pageSize, last - offset)
			local rows = {}
			for i = 1, count do rows[i] = item(kind, last - offset - i + 1, false, detail) end
			local after = offset + count
			state.lastPage = after == last
			payload.repository[name] = connection(rows, if state.lastPage then nil else tostring(after), last)
		end
		return { stdout = 'HTTP/2 200\r\n\r\n' .. encode({ data = payload }), stderr = '', status = 0 }
	end
	tern.timer = function(_, cb) table.insert(pending, cb) end
	runtime.exec = function(argv, opts, done)
		if argv[1] == 'gh' then
			local req = decode(opts.stdin)
			table.insert(pending, function() done(answer(req.query, req.variables)) end)
		elseif argv[6] == 'mirror-revision' then
			local revision = if stillExists and confirmedMissing and revised then 'r1' else '0'
			table.insert(pending, function() done({stdout=revision, stderr='', status=0}) end)
		else
			assert(argv[5] == 'snapshot' and argv[6] == 'mirror-write' and argv[7] == '0', table.concat(argv, ' '))
			assert(not stillExists and confirmedMissing and completions == 0 and writes == 0)
			for kind in kinds do
				assert(scan[kind].lastPage and scan[kind].latest and scan[kind].oldest,
					'persisted before scanning and publishing ' .. kind)
			end
			writes += 1
			local snapshot = decode(opts.stdin)
			-- Persistence remains pending for one scheduler turn after requesting it.
			table.insert(pending, function()
				assert(completions == 0, 'completed before persistence returned')
				saved = snapshot
				done({ stdout = '1-fixture', stderr = '', status = if revised then 5 else 0 })
			end)
		end
	end
	data.sync(repo, identity, previous, function() return true end, function(snapshot, err, _, changed)
		completions += 1
		result, failure, revisionChanged = snapshot, err, changed
	end, function(kind, upserts)
		assert(kinds[kind] and #upserts > 0, 'progress must contain a kind and row upserts')
		assert(writes == 0 and completions == 0 and visible.issues[missing] == obsolete)
		for _, row in upserts do
			assert(row.id == kind .. ':' .. row.number)
			if row.id == reverted then
				assert(row.title == 'prior ' .. reverted and visible.issues[reverted] == priorPreview)
				visible.issues[reverted] = row
				continue
			end
			if kind == 'issues' and row.number == linkedIssue then
				assert(row.state == 'OPEN' and row.updatedAt == visible.issues[row.id].updatedAt)
				assert(row.closedByPullRequestsReferences.nodes[1].state == 'MERGED')
				visible.issues[row.id] = row
				continue
			end
			assert(row.title == 'remote ' .. row.id)
			local state = scan[kind]
			if row.number == last then
				assert(state.expanded and not state.continued, 'latest ' .. kind .. ' was not published before later pages')
				assert(row.labels.totalCount == 2 and not row.labels.pageInfo.hasNextPage and #row.labels.nodes == 2)
				assert(row.labels.nodes[2].name == 'second')
				state.latest = true
			else
				assert(row.number == 1 and state.continued)
				state.oldest = true
			end
			visible[kind][row.id] = row
		end
	end, lastVisible)
	for _ = 1, 500 do
		if #pending == 0 then break end
		table.remove(pending, 1)()
	end
	assert(#pending == 0 and completions == 1 and confirmedMissing)
	assert(scan.issues.latest and scan.prs.latest and visible.issues[missing] == obsolete)
	assert(visible.issues[reverted].title == 'prior ' .. reverted, 'baseline-equal detail did not replace the older preview')
	if revised then
		assert(result == nil and failure == nil and revisionChanged and writes == (if stillExists then 0 else 1),
			'a receipt change must restart either a fenced publication or an interrupted pagination')
	elseif stillExists then
		assert(result == nil and type(failure) == 'string' and writes == 0, 'unverified absence must not complete')
	else
		assert(result and result.complete and failure == nil and writes == 1 and saved.complete)
		for kind in kinds do
			assert(#result[kind] == last and #saved[kind] == last)
			assert(byId(result[kind], kind .. ':1').title == 'remote ' .. kind .. ':1')
			assert(byId(saved[kind], kind .. ':' .. last).labels.nodes[2].name == 'second')
		end
		local associated = byId(saved.issues, 'issues:' .. linkedIssue)
		assert(associated.closedByPullRequestsReferences.nodes[1].repository.nameWithOwner == 'other/repo')
		assert(associated.closedByPullRequestsReferences.nodes[1].state == 'MERGED')
		assert(byId(saved.issues, 'issues:' .. last).closedByPullRequestsReferences.nodes[2].state == 'CLOSED')
		assert(not byId(result.issues, missing) and not byId(saved.issues, missing))
	end
end

scenario(false)
scenario(true)
scenario(false, true)
scenario(true, true)

-- An old payload and its old success stamp still provide a baseline on reopen,
-- but only a scan from the current receipt revision makes them current.
local baseline = {complete=true, viewer=identity.viewer, viewerId=identity.viewerId, host=repo.host,
	repoId=identity.repoId, repoUrl=identity.webUrl, observedAt='2026-01-01T00:00:00Z',
	checkedEpoch=120, reconciledEpoch=100, issues={}, prs={}}
tern.fs = {read=function() return encode({generation='23-cache', snapshot=table.clone(baseline)}) end}
for _, case in {
	{probe='true\n0\n23-cache 140 110', checked=140},
	{probe='true\nr7\n23-cache 140 110 0', checked=nil},
	{probe='true\nr7\n23-cache 140 110 r7', checked=140},
} do
	runtime.exec = function(argv, _, done)
		assert(argv[6] == 'mirror-probe')
		done({stdout=case.probe, stderr='', status=0})
	end
	data.cached(repo, identity, function(snapshot, err)
		assert(not err and snapshot.complete and snapshot.checkedEpoch == case.checked and snapshot.reconciledEpoch == 110)
	end)
end
print('Warm refresh publishes verified Issue and PR upserts before reconciliation and persistence.')
LUAU
} > "$tmp/refresh.luau"
"${LUAU:-luau}" "$tmp/refresh.luau"
