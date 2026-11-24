#!/bin/sh
# Run with LUAU=/path/to/luau sh tests/pr-live-refresh.sh.
set -eu
src=$(dirname "$0")/..
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-pr-live-test.XXXXXXXX")
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
local tern = {plugin = {dir = '/plugin', data = '/data'}, json = {encode = encode, null = {}}}
local runtime = {decode = decode, failure = function(raw, err) return err or raw.stderr end}
local function require(name) assert(name == './runtime', name); return runtime end
local data = (function()
LUAU
    cat "$src/maintenance_data.luau"
    printf '%s\n' 'end)()'
    cat <<'LUAU'
local repo = {host = 'github.test', owner = 'owner', name = 'repo'}
local identity = {repoId = 'repo-id', viewerId = 'viewer-id', viewer = 'viewer', webUrl = 'https://github.test/owner/repo'}
local specs = {'labels', 'closingIssuesReferences', 'reviewThreads', 'latestReviews', 'reviewRequests'}
local function connection(nodes, cursor, total)
	return {nodes = nodes, totalCount = total or #nodes, pageInfo = {hasNextPage = cursor ~= nil, endCursor = cursor}}
end
local function child(spec, index)
	local node = {id = spec .. ':' .. index}
	if spec == 'labels' then node.name = 'label ' .. index
	elseif spec == 'closingIssuesReferences' then node.number, node.url = index, identity.webUrl .. '/issues/' .. index
	elseif spec == 'reviewThreads' then node.isResolved = index == 1
	elseif spec == 'latestReviews' then
		node.state, node.url, node.author = 'APPROVED', 'https://github.test/review/' .. index, {login = 'reviewer', __typename = 'User'}
		node.commit, node.submittedAt = {oid = 'head'}, '2026-01-01T01:00:00Z'
	else node.requestedReviewer = {__typename = 'User', login = 'requested' .. index} end
	return node
end
local function row(number, old)
	local item = {id = 'pr:' .. number, number = number, updatedAt = 'unchanged', title = 'PR ' .. number,
		url = identity.webUrl .. '/pull/' .. number, state = if old or number <= 65 then 'OPEN' elseif number % 2 == 0 then 'MERGED' else 'CLOSED',
		headRefOid = 'head', baseRefName = 'main', isDraft = false, isCrossRepository = false, mergeable = 'MERGEABLE',
		author = {login = 'author'}, reviewDecision = 'APPROVED',
		commits = {nodes = {{commit = {oid = 'head', statusCheckRollup = {state = if old then 'PENDING' else 'SUCCESS', contexts = {totalCount = 4}}}}}}}
	item.bodyHTML = if number == 1 then '<p>拆自 <a data-hovercard-type="pull_request" href="https://github.test/owner/repo/pull/1241" data-url="https://github.test/owner/repo/issues/1241">#1241</a>，关联 <a data-hovercard-type="issue" href="https://github.test/owner/repo/issues/522">#522</a></p>' else ""
	if old then item.bodyIssueReferences = {nodes={}, complete=true}; item.bodyHTML = nil end
	for _, spec in specs do
		item[spec] = if not old and (number == 2 or number == 101) then connection({child(spec, 1)}, spec .. ':cursor', 2) else connection({})
	end
	return item
end
local function freeze(value)
	for _, childValue in value do if type(childValue) == 'table' then freeze(childValue) end end
	table.freeze(value)
end
local function scenario(options)
	options = options or {}
	local prior = {complete = true, host = repo.host, repoId = identity.repoId, repoUrl = identity.webUrl,
		viewerId = identity.viewerId, viewer = identity.viewer, observedAt = '2026-01-01T00:00:00Z',
		checkedEpoch = 123, reconciledEpoch = 100, prs = {row(1, true)}}
	for number = 101, 132 do table.insert(prior.prs, row(number, true)) end
	local closed = row(999, true)
	closed.state = 'CLOSED'
	table.insert(prior.prs, closed)
	freeze(prior)
	local pending, requests, lookedUp, expanded = {}, {}, {}, {}
	local alive, completed, result, failure, identityChanged = true, 0, nil, nil, nil
	local rootPages, nodeBatches = 0, 0
	local function answer(query, vars)
		local value = {viewer = {id = identity.viewerId, login = identity.viewer},
			repository = {id = identity.repoId, nameWithOwner = repo.owner .. '/' .. repo.name}}
		local phase
		if vars.id then
			phase = 'nested'
			local number = assert(tonumber(vars.id:match('^pr:(%d+)$')))
			assert(number == 2 or number == 101)
			local spec = assert(vars.cursor:match('^(%a+):cursor$'))
			assert(query:find(spec .. '(first:50,after:$cursor)', 1, true))
			value.node = {id = vars.id, number = number, updatedAt = 'unchanged', headRefOid = 'head', repository = {id = identity.repoId}}
			value.node[spec] = connection({child(spec, 2)}, nil, 2)
			expanded[vars.id .. ':' .. spec] = true
			if options.bad == 'nested-count' then value.node[spec].totalCount = 3 end
			if options.bad == 'nested-duplicate' then value.node[spec].nodes[1] = child(spec, 1) end
			if options.bad == 'nested-cursor' then value.node[spec].pageInfo = {hasNextPage = true, endCursor = vars.cursor} end
		elseif vars.ids then
			phase = 'missing'
			nodeBatches += 1
			value.nodes = {}
			assert(#vars.ids <= 30)
			for _, id in vars.ids do
				local number = assert(tonumber(id:match('^pr:(%d+)$')))
				assert(number >= 101 and number <= 132 and not lookedUp[id], 'only absent previously-open PRs are fetched')
				lookedUp[id] = true
				local item = row(number, false)
				item.repository = {id = identity.repoId, nameWithOwner = 'owner/repo'}
				if options.bad == 'missing-null' then item = tern.json.null
				elseif options.bad == 'missing-transferred' then item.repository.id = 'other'
				elseif options.bad == 'missing-name' then item.repository.nameWithOwner = 'other/repo'
				elseif options.bad == 'missing-open' then item.state = 'OPEN'
				elseif options.bad == 'missing-id' then item.id = 'unexpected' end
				table.insert(value.nodes, item)
			end
			if options.bad == 'missing-short' then table.remove(value.nodes) end
		else
			rootPages += 1
			phase = if rootPages == 1 then 'root' else 'root2'
			assert(query:find('states:[OPEN]', 1, true) and not query:find('issues(first', 1, true))
			for _, field in {'statusCheckRollup', 'latestReviews', 'reviewThreads', 'reviewRequests', 'title url'} do
				assert(query:find(field, 1, true), 'missing full volatile evidence: ' .. field)
			end
			local pageSize = assert(tonumber(query:match('pullRequests%(first:(%d+)')))
			local offset = if vars.cursor then assert(tonumber(vars.cursor)) else 0
			local after = math.min(offset + pageSize, 65)
			local items = {}
			for number = offset + 1, after do table.insert(items, row(number, false)) end
			value.repository.pullRequests = connection(items, if after < 65 then tostring(after) else nil, 65)
			if options.bad == 'root-count' and rootPages > 1 then value.repository.pullRequests.totalCount = 66 end
			if options.bad == 'root-short' and after == 65 then table.remove(items) end
			if options.bad == 'root-state' then items[1].state = 'CLOSED' end
			if options.bad == 'nested-shape' then items[2].reviewThreads.nodes[1].isResolved = nil end
		end
		if options.phase == phase then
			if options.change == 'viewer-id' then value.viewer.id = 'another-viewer'
			elseif options.change == 'viewer-login' then value.viewer.login = 'renamed'
			elseif options.change == 'repo-id' then value.repository.id = 'another-repo'
			elseif options.change == 'repo-name' then value.repository.nameWithOwner = 'other/repo' end
		end
		local payload = {data = value}
		if options.bad == 'graphql-partial' then payload.errors = {{type = 'INTERNAL', message = 'incomplete'}} end
		if options.bad == 'graphql-forbidden' then payload.errors = {{type = 'FORBIDDEN', message = 'forbidden'}} end
		return {stdout = 'HTTP/2 200\r\n\r\n' .. encode(payload), stderr = '', status = 0}, phase
	end
	tern.timer = function(_, cb) table.insert(pending, cb) end
	runtime.exec = function(argv, opts, done)
		assert(argv[1] == 'gh', 'live refresh must never touch the mirror or receipts')
		assert(argv[4] == '--hostname' and argv[5] == repo.host)
		local request = decode(opts.stdin)
		assert(request.variables.owner == repo.owner and request.variables.name == repo.name)
		table.insert(requests, request)
		table.insert(pending, function()
			local response, phase = answer(request.query, request.variables)
			if options.late == phase then alive = false end
			done(response)
		end)
	end
	data.refreshPRs(repo, identity, if options.cold then nil else prior, function() return alive end, function(rows, err, changed)
		completed += 1
		result, failure, identityChanged = rows, err, changed
	end)
	for _ = 1, 200 do
		if #pending == 0 then break end
		table.remove(pending, 1)()
	end
	assert(#pending == 0 and prior.checkedEpoch == 123 and prior.reconciledEpoch == 100)
	assert(prior.prs[1].commits.nodes[1].commit.statusCheckRollup.state == 'PENDING')
	if options.late then
		assert(not alive and completed == 0, 'invalidated callbacks must be discarded')
	elseif options.change or options.bad then
		assert(completed == 1 and result == nil and type(failure) == 'string', 'partial or changed-identity reads must fail without cached fallback')
		assert(identityChanged == (if options.change or options.bad == 'graphql-forbidden' then true else nil))
	else
		assert(completed == 1 and failure == nil and not identityChanged)
		assert(#result == (if options.cold then 65 else 97) and rootPages == 3)
		assert(nodeBatches == (if options.cold then 0 else 2))
		local indexed = {}
		for _, item in result do assert(not indexed[item.id]); indexed[item.id] = item end
		assert(indexed['pr:65'].state == 'OPEN', 'new PRs must appear')
		local current = indexed['pr:1']
		assert(current.updatedAt == prior.prs[1].updatedAt and current.headRefOid == prior.prs[1].headRefOid)
		assert(current.commits.nodes[1].commit.statusCheckRollup.state == 'SUCCESS', 'CI-only changes must not use the cached row')
		assert(current.bodyHTML == nil and current.bodyIssueReferences.complete)
		assert(#current.bodyIssueReferences.nodes == 1 and current.bodyIssueReferences.nodes[1].number == 522,
			'plain related Issue links are included, but a split-from PR link is not an Issue')
		for _, number in (if options.cold then {2} else {2, 101}) do
			for _, spec in specs do
				local part = indexed['pr:' .. number][spec]
				assert(expanded['pr:' .. number .. ':' .. spec] and #part.nodes == 2 and not part.pageInfo.hasNextPage)
			end
		end
		assert(indexed['pr:2'].reviewThreads.nodes[2].isResolved == false)
		assert(indexed['pr:2'].latestReviews.nodes[2].author.login == 'reviewer')
		assert(indexed['pr:2'].reviewRequests.nodes[2].requestedReviewer.login == 'requested2')
		if not options.cold then
			assert(indexed['pr:101'].state == 'CLOSED' and indexed['pr:102'].state == 'MERGED')
			assert(not indexed['pr:999'] and not lookedUp['pr:999'])
		end
	end
end
scenario()
scenario({cold = true})
for _, phase in {'root', 'root2', 'nested', 'missing'} do
	for _, change in {'viewer-id', 'viewer-login', 'repo-id', 'repo-name'} do scenario({phase = phase, change = change}) end
	scenario({late = phase})
end
for _, bad in {'root-count', 'root-short', 'root-state', 'nested-shape', 'nested-count', 'nested-duplicate', 'nested-cursor',
	'missing-null', 'missing-transferred', 'missing-name', 'missing-open', 'missing-id', 'missing-short', 'graphql-partial', 'graphql-forbidden'} do
	scenario({bad = bad})
end
print('Live PR refresh hydrates every open and transitioned PR without mirror writes, stale CI, partial results, or invalidated callbacks.')
LUAU
} > "$tmp/pr-live.luau"
"${LUAU:-luau}" "$tmp/pr-live.luau"
