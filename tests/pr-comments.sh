#!/bin/sh
# Run with LUAU=/path/to/luau sh tests/pr-comments.sh.
set -eu
src=$(dirname "$0")/..
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ternmate-pr-comments.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
{
    cat <<'LUAU'
local payload
local tern = { runtime = { os = 'linux' }, json = { array = function() return {} end, decode = function() return payload end } }
local runtime = (function()
LUAU
    cat "$src/runtime.luau"
    printf '%s\n' 'end)()' 'local function require(name) assert(name == "./runtime"); return runtime end' 'local materials = (function()'
    cat "$src/materials.luau"
    printf '%s\n' 'end)()'
    cat <<'LUAU'
local head, old = string.rep('a', 40), string.rep('b', 40)
local repo = { host = 'github.test', owner = 'owner', name = 'repo' }
local account = { repoId = 'repo-id', viewerId = 'viewer-id' }
local function page(nodes, cursor, total)
	return { nodes = nodes, totalCount = total or #nodes, pageInfo = { hasNextPage = cursor ~= nil, endCursor = cursor } }
end
local function collect(secondPage, finalHead)
	local function exec(argv, _, reply)
		local query, cursor
		for _, arg in argv do
			query = query or arg:match('^query=(.+)')
			cursor = cursor or arg:match('^cursor=(.+)$')
		end
		assert(query and argv[1] == 'gh')
		local node = { id = 'pr-id', headRefOid = head }
		local status = 0
		if query:find('on PullRequest { id headRefOid comments(', 1, true) then
			if cursor then
				assert(cursor == 'discussion-2')
				node.comments = page({ { id = 'comment-2', body = 'Second-page question', url = 'https://github.test/owner/repo/pull/7#issuecomment-2' } }, nil, 2)
				if secondPage == 'wrong-head' then node.headRefOid = old end
			else
				node.comments = page({ { id = 'comment-1', body = 'Conversation question' } }, 'discussion-2', 2)
			end
			payload = { data = { node = node } }
			if cursor and secondPage == 'forbidden' then status, payload = 1, { errors = { { type = 'FORBIDDEN' } } } end
		elseif query:find(' reviews(', 1, true) then
			if cursor then
				assert(cursor == 'reviews-2')
				node.reviews = page({ { id = 'review-2', body = 'Older review question', state = 'COMMENTED', commit = { oid = old } } }, nil, 2)
			else
				node.reviews = page({ { id = 'review-1', body = 'General review question', state = 'COMMENTED', commit = { oid = head } } }, 'reviews-2', 2)
			end
			payload = { data = { node = node } }
		elseif query:find('reviewThreads(', 1, true) then
			node.reviewThreads = page({})
			payload = { data = { node = node } }
		else
			node.__typename, node.number, node.url = 'PullRequest', 7, 'https://github.test/owner/repo/pull/7'
			node.title, node.body = 'Fixture PR', ''
			if query:find('statusCheckRollup', 1, true) then
				node.commits = { nodes = { { commit = { oid = head } } } }
			elseif not query:find('title', 1, true) then
				node.headRefOid = finalHead
			end
			payload = { data = { viewer = { id = account.viewerId }, repository = {
				id = account.repoId, nameWithOwner = 'owner/repo', pullRequest = node,
			} } }
		end
		reply({ status = status, stdout = 'payload', stderr = '', timed_out = false })
	end
	local result, err
	materials.collect(exec, repo, account, 'pr', 7, { head = head }, function() return true end, function(data, problem)
		result, err = data, problem
	end)
	return result, err
end

local full = assert(collect('readable', head))
assert(full.discussion.complete and #full.discussion.comments == 2)
assert(full.discussion.comments[2].body == 'Second-page question' and full.discussion.comments[2].url:find('#issuecomment-2', 1, true))
assert(full.overallReviews.complete and #full.overallReviews.reviews == 2)
assert(full.overallReviews.reviews[1].body == 'General review question' and full.overallReviews.reviews[1].onCurrentHead)
assert(full.overallReviews.reviews[2].body == 'Older review question' and full.overallReviews.reviews[2].onCurrentHead == false)
for _, failure in { 'wrong-head', 'forbidden' } do
	local partial = assert(collect(failure, head)).discussion
	assert(not partial.complete and partial.error and #partial.comments == 1 and partial.comments[1].body == 'Conversation question')
end
local stale, err = collect('readable', old)
assert(not stale and err, 'do not pass comments from a stale task snapshot to omp')
print('PR discussion and overall review pagination, partial coverage, and head binding passed.')

local function linkedHeads(mode)
	local result, problem
	materials.closedIssueMergedHeads(function(argv, _, reply)
		assert(argv[1] == 'gh' and table.concat(argv, ' '):find('closedByPullRequestsReferences', 1, true))
		local nextPage = table.find(argv, 'cursor=links-2') ~= nil
		local links = if mode == 'removed' then page({})
			elseif nextPage then page({{id = 'same', state = 'MERGED', headRefOid = head, repository = {id = account.repoId}}}, nil, 3)
			else page({
				{id = 'fork', state = 'MERGED', headRefOid = old, repository = {id = 'other-id'}},
				{id = 'open', state = 'OPEN', headRefOid = old, repository = {id = account.repoId}},
			}, 'links-2', 3)
		payload = { data = { viewer = { id = account.viewerId }, repository = {
			id = account.repoId, nameWithOwner = 'owner/repo',
			issue = {
				id = 'issue-id', __typename = 'Issue', number = 7, url = 'https://github.test/owner/repo/issues/7',
				state = if nextPage and mode == 'reopened' then 'OPEN' else 'CLOSED',
				closedByPullRequestsReferences = links,
			},
		} } }
		reply({ status = 0, stdout = 'payload', stderr = '', timed_out = false })
	end, repo, account, 7, function(heads, why) result, problem = heads, why end)
	return result, problem
end
local heads = assert(linkedHeads('linked'))
assert(#heads == 1 and heads[1] == head, 'only a live same-repository merged link proves ancestry')
assert(#assert(linkedHeads('removed')) == 0, 'removed association no longer supplies a head')
local reopened, linkError = linkedHeads('reopened')
assert(not reopened and linkError, 'issue that reopens mid-scan must not be cleaned')
print('Cleanup revalidates complete live Issue associations and terminal state.')
LUAU
} > "$tmp/pr-comments.luau"
"${LUAU:-luau}" "$tmp/pr-comments.luau"
