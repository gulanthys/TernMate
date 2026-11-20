--!strict

local runtime = require('./runtime')
local materials = {}

type Kind = "issue" | "pr"
export type TaskIdentity = { host: string, owner: string, name: string, kind: Kind, number: number, id: string }
type Callback = (any, Problem?) -> ()
type Problem = { kind: string, message: string }
type Version = {
	head: string,
	merge: string?,
	base: string?,
	baseRef: string?,
	headRef: string?,
	headRepo: string?,
	number: number,
}

local TASK_VARS = "$owner: String!, $name: String!, $number: Int!"
local PAGE = "pageInfo { hasNextPage endCursor } totalCount"
local TASK_FIELDS = "__typename id number url title body createdAt updatedAt author { login }"
local COMMENT_FIELDS = "id url body author { login } authorAssociation createdAt updatedAt isMinimized"
local THREAD_FIELDS = "id isResolved isOutdated path subjectType diffSide startDiffSide line startLine originalLine originalStartLine"
local VERSION_FIELDS = [[
	headRefOid headRefName headRepository { nameWithOwner }
	baseRefOid baseRefName
	potentialMergeCommit { oid parents(first: 2) { totalCount nodes { oid } } }
]]

local ISSUE = "query(" .. TASK_VARS .. ") { repository(owner: $owner, name: $name) { nameWithOwner issue(number: $number) { " .. TASK_FIELDS .. " } } }"
local PR = "query(" .. TASK_VARS .. ") { repository(owner: $owner, name: $name) { nameWithOwner pullRequest(number: $number) { " .. TASK_FIELDS .. VERSION_FIELDS .. " mergeable reviewDecision } } }"
local HEAD = "query(" .. TASK_VARS .. ") { repository(owner: $owner, name: $name) { nameWithOwner pullRequest(number: $number) { __typename id number url headRefOid } } }"
local PUSH_TARGET = "query(" .. TASK_VARS .. ") { repository(owner: $owner, name: $name) { nameWithOwner pullRequest(number: $number) { __typename id number url state headRefOid headRefName headRepository { nameWithOwner } } } }"
local DISCUSSION = "query($id: ID!, $cursor: String) { node(id: $id) { ... on Issue { id comments(first: 50, after: $cursor) { " .. PAGE .. " nodes { " .. COMMENT_FIELDS .. " } } } } }"
local THREADS = "query($id: ID!, $cursor: String) { node(id: $id) { ... on PullRequest { id headRefOid reviewThreads(first: 100, after: $cursor) { " .. PAGE .. " nodes { id isResolved } } } } }"
local OVERALL_REVIEWS = "query($id: ID!, $cursor: String) { node(id: $id) { ... on PullRequest { id headRefOid latestReviews(first: 50, after: $cursor) { " .. PAGE .. " nodes { id url author { login __typename } state submittedAt commit { oid } body } } } } }"
local REPLIES = "query($id: ID!, $cursor: String) { node(id: $id) { ... on PullRequestReviewThread { " .. THREAD_FIELDS .. [[
	pullRequest { id headRefOid }
	comments(first: 50, after: $cursor) { ]] .. PAGE .. " nodes { " .. COMMENT_FIELDS .. [[
		path line startLine originalLine originalStartLine outdated commit { oid } originalCommit { oid }
	} }
} } }
]]
local CHECKS = "query(" .. TASK_VARS .. ", $cursor: String) {" .. [[
	repository(owner: $owner, name: $name) {
		nameWithOwner
		pullRequest(number: $number) {
			headRefOid
			commits(last: 1) {
				nodes { commit {
					oid
					statusCheckRollup {
						id state
						contexts(first: 100, after: $cursor) { ]] .. PAGE .. [[
							nodes {
								__typename
								... on CheckRun {
									id status conclusion name url permalink detailsUrl startedAt completedAt
									checkSuite { id app { slug } }
								}
								... on StatusContext { id context state targetUrl createdAt }
							}
						}
					}
				} }
			}
		}
	}
}
]]
local WORKFLOW = [[
query($id: ID!) {
	node(id: $id) { ... on CheckSuite { id workflowRun { resourcePath } } }
}
]]

local function problem(kind: string, message: string): Problem
	return { kind = kind, message = message }
end

local function text(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

local function sha(value: any): string?
	if type(value) == "string" and #value == 40 and value:match("^%x+$") then
		return value:lower()
	end
	return nil
end

local function idText(value: any): string?
	if type(value) == "number" and value > 0 and value <= 9007199254740991 and value % 1 == 0 then
		return string.format("%.0f", value)
	end
	return if type(value) == "string" and value:match("^[1-9]%d*$") then value else nil
end

local function sameName(a: any, b: any): boolean
	return type(a) == "string" and type(b) == "string" and a:lower() == b:lower()
end

local function repoName(repo: runtime.Repo): string
	return repo.owner .. "/" .. repo.name
end

local function validTarget(repo: runtime.Repo, number: number): boolean
	return type(number) == "number" and number >= 1 and number <= 2147483647 and number % 1 == 0
		and repo.host:match("^[%w][%w.-]*$") ~= nil and repo.owner:match("^[%w][%w_-]*$") ~= nil
		and repo.name:match("^[%w_.-]+$") ~= nil and repo.name ~= "." and repo.name ~= ".."
end

-- Sources are data. Never follow an API-supplied URL in an argv or carry URL credentials into materials.
local function sourceUrl(value: any): string?
	if type(value) ~= "string" then return nil end
	local origin, tail = value:match("^(https?://[%w.:%-]+)([^%s%c]*)$")
	if not origin or not tail or tail:sub(1, 1) ~= "/" then return nil end
	return origin .. (tail:match("^[^?#]*") or "")
end

local function repoPath(value: any, repo: runtime.Repo): string?
	if type(value) ~= "string" then return nil end
	local path = value
	if path:sub(1, 1) ~= "/" then
		local url = sourceUrl(value)
		if not url then return nil end
		local host, rest = url:match("^https?://([^/]+)(/.*)$")
		if not sameName(host, repo.host) or not rest then return nil end
		path = rest
	end
	local prefix = "/" .. repoName(repo) .. "/"
	if not sameName(path:sub(1, #prefix), prefix) then return nil end
	return path:sub(#prefix + 1)
end

local function apiProblem(result: runtime.Result?, err: string?, graphError: any): Problem
	local category = if type(graphError) == "table" then tostring(graphError.type or ""):lower() else ""
	local extension = if type(graphError) == "table" and type(graphError.extensions) == "table" then tostring(graphError.extensions.code or ""):lower() else ""
	local stderr = if result then result.stderr:lower() else ""
	local function has(pattern: string): boolean
		return stderr:find(pattern, 1, true) ~= nil
	end
	if category == "rate_limited" or has("rate limit") or has("http 429") then
		return problem("limited", if result and result.status ~= 0 then runtime.failure(result, nil) else "GitHub 限流；等待解除后重试。")
	elseif category == "forbidden" or extension == "forbidden" or has("http 403") or has("http 401")
		or has("gh auth login") or has("resource not accessible") or has("bad credentials") then
		return problem("permission", "GitHub 未登录或权限不足；检查 gh auth status 和仓库权限。")
	elseif category == "not_found" or has("http 404") or has("http 410") then
		return problem("inaccessible", "GitHub 资源不存在、已过期或当前账号不可访问。")
	elseif extension == "undefinedfield" or extension == "undefinedtype" or has("http 501") then
		return problem("unsupported", "当前 GitHub 主机不支持此字段或接口。")
	elseif not result then
		return problem("unknown", "无法启动 gh；检查安装与权限。")
	elseif result.timed_out or result.status ~= 0 then
		return problem("unknown", runtime.failure(result, err))
	end
	return problem("unknown", "GitHub 返回的结果不完整或无法解析。")
end

local function graphql(exec: runtime.Exec, repo: runtime.Repo, query: string, fields: { string }, done: Callback)
	local argv = { "gh", "api", "graphql", "--hostname", repo.host, "-f", "query=" .. query }
	for _, field in ipairs(fields) do table.insert(argv, field) end
	exec(argv, nil, function(result, err)
		-- gh may exit nonzero for GraphQL errors while still returning structured JSON.
		local payload: any = if result and result.stdout ~= "" then runtime.decode(result.stdout) else nil
		if type(payload) == "table" and type(payload.errors) == "table" and next(payload.errors) ~= nil then
			done(nil, apiProblem(result, err, payload.errors[1]))
		elseif result and result.status == 0 and not result.timed_out and type(payload) == "table" and type(payload.data) == "table" then
			done(payload.data, nil)
		else
			done(nil, apiProblem(result, err, nil))
		end
	end)
end

local function rest(exec: runtime.Exec, repo: runtime.Repo, endpoint: string, done: Callback)
	exec({ "gh", "api", "--hostname", repo.host, "--method", "GET", "repos/" .. repoName(repo) .. "/" .. endpoint }, nil, function(result, err)
		local decoded = runtime.json(result, err)
		if type(decoded) == "table" and result and not result.timed_out then
			done(decoded, nil)
		else
			done(nil, apiProblem(result, err, nil))
		end
	end)
end

local function repoFields(repo: runtime.Repo): { string }
	return { "-f", "owner=" .. repo.owner, "-f", "name=" .. repo.name }
end

local function taskFields(repo: runtime.Repo, number: number): { string }
	local fields = repoFields(repo)
	table.insert(fields, "-F")
	table.insert(fields, "number=" .. tostring(number))
	return fields
end

local function withCursor(fields: { string }, cursor: string?): { string }
	if cursor then
		table.insert(fields, "-f")
		table.insert(fields, "cursor=" .. cursor)
	end
	return fields
end

local function actual(repo: runtime.Repo, kind: Kind, number: number, data: any): (TaskIdentity?, any)
	local repository = data and data.repository
	if type(repository) ~= "table" or not sameName(repository.nameWithOwner, repoName(repo)) then return nil, nil end
	local task = if kind == "pr" then repository.pullRequest else repository.issue
	local graphType = if kind == "pr" then "PullRequest" else "Issue"
	local path = (if kind == "pr" then "pull/" else "issues/") .. tostring(number)
	if type(task) ~= "table" or task.__typename ~= graphType or task.number ~= number
		or not sourceUrl(task.url) or repoPath(task.url, repo) ~= path then
		return nil, nil
	end
	local id = text(task.id)
	local owner, name = string.match(repository.nameWithOwner, "^([^/]+)/([^/]+)$")
	if not id or not owner or not name then return nil, nil end
	return { host = repo.host:lower(), owner = owner, name = name, kind = kind, number = task.number, id = id }, task
end

local function readHead(exec: runtime.Exec, repo: runtime.Repo, number: number, done: (string?, string?, string?) -> ())
	if not validTarget(repo, number) then
		done(nil, "PR 任务身份无效。", nil)
		return
	end
	graphql(exec, repo, HEAD, taskFields(repo, number), function(data, err)
		if err then done(nil, err.message, nil); return end
		local identity, task = actual(repo, "pr", number, data)
		local revision = if identity then sha(task.headRefOid) else nil
		if identity and revision then
			done(revision, nil, identity.id)
		else
			done(nil, "无法核对目标 PR 和 head SHA。", nil)
		end
	end)
end

function materials.head(exec: runtime.Exec, repo: runtime.Repo, number: number, done: (sha: string?, error: string?) -> ())
	readHead(exec, repo, number, function(revision, err)
		done(revision, err)
	end)
end

function materials.pushTarget(exec: runtime.Exec, repo: runtime.Repo, number: number, done: (string?, string?, string?, string?) -> ())
	if not validTarget(repo, number) then done(nil, nil, nil, "PR 身份无效。"); return end
	graphql(exec, repo, PUSH_TARGET, taskFields(repo, number), function(data, err)
		if err then done(nil, nil, nil, err.message); return end
		local identity, task = actual(repo, "pr", number, data)
		if not identity or task.state ~= "OPEN" then done(nil, nil, nil, "只能为可核对的开放 PR 准备推送命令。"); return end
		local revision = sha(task.headRefOid)
		local branch = text(task.headRefName)
		local fullName = if type(task.headRepository) == "table" then text(task.headRepository.nameWithOwner) else nil
		local owner: string?, name: string? = nil, nil
		if fullName then owner, name = fullName:match("^([%w][%w_-]*)/([%w_.-]+)$") end
		if not revision or not branch or branch:find("%c") or not owner or not name or name == "." or name == ".." then
			done(nil, nil, nil, "无法核对 PR 源仓库、源分支或 head；不会猜测目标。"); return
		end
		done(revision, "https://" .. repo.host .. "/" .. owner .. "/" .. name .. ".git", "refs/heads/" .. branch, nil)
	end)
end

local function walk(fetch: (string?, Callback) -> (), visit: (any) -> Problem?, done: (Problem?) -> ())
	local seen: { [string]: boolean } = {}
	local seenIds: { [string]: boolean } = {}
	local count, expected = 0, nil :: number?
	local function page(cursor: string?)
		fetch(cursor, function(connection, err)
			if err then done(err); return end
			local info = if type(connection) == "table" then connection.pageInfo else nil
			if type(info) ~= "table" or type(info.hasNextPage) ~= "boolean" or type(connection.nodes) ~= "table"
				or type(connection.totalCount) ~= "number" then
				done(problem("unknown", "GitHub 分页响应不完整。"))
				return
			end
			if expected ~= nil and expected ~= connection.totalCount then
				done(problem("unknown", "GitHub 数据在分页期间变化；请刷新后重试。"))
				return
			end
			expected = connection.totalCount
			for _, node in ipairs(connection.nodes) do
				if type(node) ~= "table" then
					done(problem("unknown", "有 GitHub 条目不可读取。"))
					return
				end
				local id = text(node.id)
				if not id or seenIds[id] then
					done(problem("unknown", "GitHub 分页条目缺少稳定身份或重复出现。"))
					return
				end
				seenIds[id] = true
				local invalid = visit(node)
				if invalid then done(invalid); return end
				count += 1
			end
			if not info.hasNextPage then
				done(if count == expected then nil else problem("unknown", "GitHub 分页未返回预期的全部条目。"))
				return
			end
			local nextCursor = text(info.endCursor)
			if not nextCursor or seen[nextCursor] or #connection.nodes == 0 then
				done(problem("unknown", "GitHub 分页游标没有前进。"))
				return
			end
			seen[nextCursor] = true
			page(nextCursor)
		end)
	end
	page(nil)
end

local function discussion(exec: runtime.Exec, repo: runtime.Repo, id: string, done: Callback)
	local comments: { any } = tern.json.array()
	walk(function(cursor, receive)
		graphql(exec, repo, DISCUSSION, withCursor({ "-f", "id=" .. id }, cursor), function(data, err)
			local node = data and data.node
			receive(if type(node) == "table" and node.id == id then node.comments else nil, err)
		end)
	end, function(comment)
		table.insert(comments, comment)
		return nil
	end, function(err)
		done(if err then nil else comments, err)
	end)
end

local function reviewThreads(exec: runtime.Exec, repo: runtime.Repo, prId: string, head: string, done: Callback)
	local ids: { string } = {}
	local threads: { any } = tern.json.array()
	local changed = problem("unverified", "PR head 在读取审查线程时发生变化；请刷新后重试。")
	local function load(index: number)
		local id = ids[index]
		if not id then done(threads, nil); return end
		local thread: any = nil
		local resolved = false
		local comments: { any } = tern.json.array()
		walk(function(cursor, receive)
			graphql(exec, repo, REPLIES, withCursor({ "-f", "id=" .. id }, cursor), function(data, err)
				if err then receive(nil, err); return end
				local node = data and data.node
				if type(node) ~= "table" or node.id ~= id or type(node.isResolved) ~= "boolean" or type(node.pullRequest) ~= "table"
					or node.pullRequest.id ~= prId then
					receive(nil, problem("unknown", "无法核对 PR 审查线程。")); return
				end
				if sha(node.pullRequest.headRefOid) ~= head then receive(nil, changed); return end
				if node.isResolved then
					resolved = true
					-- Stop reading if the thread stopped qualifying after the thread page was fetched.
					receive(nil, problem("resolved", "线程已解决。"))
					return
				end
				local connection = node.comments
				if not thread then
					node.comments = comments
					node.pullRequest = nil
					thread = node
				end
				receive(connection, nil)
			end)
		end, function(comment)
			table.insert(comments, comment)
			return nil
		end, function(err)
			if err and not resolved then done(nil, err); return end
			if thread and not resolved then table.insert(threads, thread) end
			load(index + 1)
		end)
	end
	walk(function(cursor, receive)
		graphql(exec, repo, THREADS, withCursor({ "-f", "id=" .. prId }, cursor), function(data, err)
			if err then receive(nil, err); return end
			local node = data and data.node
			if type(node) ~= "table" or node.id ~= prId then receive(nil, problem("unknown", "无法读取 PR 审查线程。")); return end
			if sha(node.headRefOid) ~= head then receive(nil, changed); return end
			receive(node.reviewThreads, nil)
		end)
	end, function(thread)
		local id = text(thread.id)
		if not id or type(thread.isResolved) ~= "boolean" then return problem("unknown", "GitHub 审查线程状态不完整。") end
		if not thread.isResolved then table.insert(ids, id) end
		return nil
	end, function(err)
		if err then done(nil, err) else load(1) end
	end)
end

local function overallReviews(exec: runtime.Exec, repo: runtime.Repo, prId: string, head: string, decision: any, done: Callback)
	local evidence: any = {decision = text(decision), head = head, reviews = tern.json.array()}
	walk(function(cursor, receive)
		graphql(exec, repo, OVERALL_REVIEWS, withCursor({ "-f", "id=" .. prId }, cursor), function(data, err)
			if err then receive(nil, err); return end
			local node = data and data.node
			if type(node) ~= "table" or node.id ~= prId or sha(node.headRefOid) ~= head then
				receive(nil, problem("unverified", "未能把整体审查对应到任务 head。")); return
			end
			receive(node.latestReviews, nil)
		end)
	end, function(review)
		if review.state == "CHANGES_REQUESTED" or review.state == "APPROVED" then
			review.onCurrentHead = type(review.commit) == "table" and sha(review.commit.oid) == head
			table.insert(evidence.reviews, review)
		end
		return nil
	end, function(err)
		evidence.complete = err == nil
		if err then evidence.error = err.message end
		done(evidence, nil)
	end)
end

local BAD: { [string]: boolean } = {
	FAILURE = true, ERROR = true, STARTUP_FAILURE = true, TIMED_OUT = true, ACTION_REQUIRED = true, CANCELLED = true, STALE = true,
}
local WAIT: { [string]: boolean } = {
	EXPECTED = true, PENDING = true, QUEUED = true, IN_PROGRESS = true, REQUESTED = true, WAITING = true,
}
local OK: { [string]: boolean } = { SUCCESS = true, SKIPPED = true, NEUTRAL = true }

local function exactChecks(exec: runtime.Exec, repo: runtime.Repo, number: number, head: string, done: (any, { any }) -> ())
	local failures: { any } = {}
	local count, pending, incomplete = 0, false, false
	local rollupState: string? = nil
	local rollupId: string? = nil
	local ci: any = { state = "unknown", head = head, failedChecks = tern.json.array() }
	walk(function(cursor, receive)
		graphql(exec, repo, CHECKS, withCursor(taskFields(repo, number), cursor), function(data, err)
			if err then receive(nil, err); return end
			local repository = data and data.repository
			local pr = if type(repository) == "table" and sameName(repository.nameWithOwner, repoName(repo)) then repository.pullRequest else nil
			local commits = if type(pr) == "table" then pr.commits else nil
			local nodes = if type(commits) == "table" then commits.nodes else nil
			local commit = if type(nodes) == "table" and type(nodes[1]) == "table" then nodes[1].commit else nil
			if type(pr) ~= "table" or sha(pr.headRefOid) ~= head or type(commit) ~= "table" or sha(commit.oid) ~= head then
				receive(nil, problem("unverified", "无法读取目标仓库中精确 head 的 CI 状态。")); return
			end
			local rollup = commit.statusCheckRollup
			if (rollup == nil or rollup == tern.json.null) and not cursor then
				receive({ nodes = {}, pageInfo = { hasNextPage = false }, totalCount = 0 }, nil)
				return
			end
			local id = if type(rollup) == "table" then text(rollup.id) else nil
			local state = if type(rollup) == "table" then text(rollup.state) else nil
			if not id or not state or (cursor and (id ~= rollupId or state ~= rollupState)) then
				receive(nil, problem("unknown", "CI 汇总不可读或在分页期间变化。")); return
			end
			rollupId, rollupState = id, state
			receive(rollup.contexts, nil)
		end)
	end, function(check)
		count += 1
		local state = if check.__typename == "StatusContext" then text(check.state)
			elseif check.__typename == "CheckRun" and check.status == "COMPLETED" then text(check.conclusion)
			elseif check.__typename == "CheckRun" and type(check.status) == "string" and WAIT[check.status] then check.status
			else nil
		if state and BAD[state] then
			table.insert(failures, check)
		elseif state and WAIT[state] then
			pending = true
		elseif not state or not OK[state] then
			incomplete = true
		end
		return nil
	end, function(err)
		ci.rollupState = rollupState
		if err then
			ci.issue = err
		elseif #failures > 0 then
			ci.state = "failed"
			if incomplete then ci.issue = problem("unknown", "另有 CI 条目的状态未知。") end
		elseif incomplete then
			ci.issue = problem("unknown", "有 CI 条目的状态未知。")
		elseif rollupState and BAD[rollupState] then
			ci.issue = problem("unknown", "CI 汇总报告失败，但未返回对应的失败检查。")
		elseif pending or (rollupState and WAIT[rollupState]) then
			ci.state = "pending"
		elseif count == 0 and (not rollupState or rollupState == "SUCCESS") then
			ci.state = "none"
		elseif count > 0 and rollupState == "SUCCESS" then
			ci.state = "success"
		else
			ci.issue = problem("unknown", "CI 汇总和检查明细不足以判断状态。")
		end
		done(ci, failures)
	end)
end

local function versionFor(task: any, head: string): Version
	local v: Version = { head = head, number = task.number }
	local merge = task.potentialMergeCommit
	local parents = if type(merge) == "table" then merge.parents else nil
	local base = sha(task.baseRefOid)
	-- Never substitute a squash, rebase, or final merge commit for the test merge.
	if base and type(parents) == "table" and parents.totalCount == 2 and type(parents.nodes) == "table"
		and type(parents.nodes[1]) == "table" and type(parents.nodes[2]) == "table"
		and sha(parents.nodes[1].oid) == base and sha(parents.nodes[2].oid) == head then
		v.merge, v.base = sha(merge.oid), base
		v.baseRef, v.headRef = text(task.baseRefName), text(task.headRefName)
		v.headRepo = if type(task.headRepository) == "table" then text(task.headRepository.nameWithOwner) else nil
	end
	return v
end

local function mergeAssociation(run: any, v: Version): boolean
	if not v.merge or not v.base or not v.baseRef or not v.headRef or not v.headRepo or run.event ~= "pull_request"
		or type(run.pull_requests) ~= "table" or type(run.repository) ~= "table" or type(run.head_repository) ~= "table"
		or not sameName(run.head_repository.full_name, v.headRepo) then return false end
	local baseRepoId, headRepoId = idText(run.repository.id), idText(run.head_repository.id)
	if not baseRepoId or not headRepoId then return false end
	for _, pr in ipairs(run.pull_requests) do
		if type(pr) == "table" and pr.number == v.number and type(pr.base) == "table" and type(pr.head) == "table"
			and type(pr.base.repo) == "table" and type(pr.head.repo) == "table"
			and idText(pr.base.repo.id) == baseRepoId and idText(pr.head.repo.id) == headRepoId
			and pr.base.ref == v.baseRef and pr.head.ref == v.headRef and sha(pr.base.sha) == v.base and sha(pr.head.sha) == v.head then
			return true
		end
	end
	return false
end

local MAX_LOG_INPUT = 1024 * 1024
local MAX_LOG_JOBS = 12
local MAX_EXCERPT_LINES = 6
local MAX_LINE_BYTES = 320

local function redact(line: string): string
	local lower = line:lower()
	-- Drop credential-bearing lines instead of guessing the grammar or length of their values.
	if lower:find("authorization", 1, true) or lower:find("bearer", 1, true) or lower:find("basic ", 1, true)
		or lower:find("password", 1, true) or lower:find("passwd", 1, true) or lower:find("secret", 1, true)
		or lower:find("token", 1, true) or lower:find("cookie", 1, true) or lower:find("credential", 1, true)
		or lower:find("private[%s_-]*key") or lower:find("api[%s_-]*key") or lower:find("access[%s_-]*key") then
		return "[省略可能含凭据的诊断行]"
	end
	local clean = line:gsub("[%w+%.%-]+://[^%s]+", "[URL 已隐藏]")
	clean = clean:gsub("[%w_+/%-=%.]+", function(word)
		if #word >= 24 or word:match("^gh[pousr]_") or word:match("^github_pat_") or word:match("^[A-Z][A-Z]IA[A-Z0-9]+$") then
			return "[值已隐藏]"
		end
		return word
	end)
	return clean
end

local function timestamp(value: any): string?
	if type(value) ~= "string" then return nil end
	local utc = value:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)[%.%d]*Z$")
	if utc then return utc end
	local y, m, d, h, min, sec, sign, zoneH, zoneM = value:match(
		"^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)[%.%d]*([+-])(%d%d):(%d%d)$")
	if not y then return nil end
	local seconds = os.time({
		year = tonumber(y) :: number, month = tonumber(m) :: number, day = tonumber(d) :: number,
		hour = tonumber(h), min = tonumber(min), sec = tonumber(sec),
	})
	local offset = (tonumber(zoneH) or 0) * 3600 + (tonumber(zoneM) or 0) * 60
	return if seconds then os.date("!%Y-%m-%dT%H:%M:%S", seconds - (if sign == "+" then offset else -offset)) else nil
end

local function excerpt(raw: string, failedSteps: { any }): any
	local lines: { string } = tern.json.array()
	if raw == "" then return problem("absent", "日志接口返回空文本。") end
	if #raw > MAX_LOG_INPUT then return problem("limited", "日志超过安全处理上限；请通过检查链接查看。") end
	if raw:find("\0", 1, true) then return problem("unknown", "日志不是可读的纯文本。") end
	local ranges: { { start: string, finish: string } } = {}
	for _, step in ipairs(failedSteps) do
		local start, finish = timestamp(step.startedAt), timestamp(step.completedAt)
		if start and finish and start <= finish then table.insert(ranges, { start = start, finish = finish }) end
	end
	local inKey, commandGroup = false, 0
	for input in raw:gmatch("[^\n]+") do
		local date, message = input:match("^(%S+)%s+(.+)$")
		local at = timestamp(date)
		if at and message then
			local line = message:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
			-- Accept color formatting, but never include OSC/DCS or other
			-- terminal control payloads in the exported evidence.
			if line:find("\27", 1, true) then continue end
			line = line:gsub("%c", "")
			if line:find("-----BEGIN", 1, true) then inKey = true end
			local lower = line:lower()
			if lower:sub(1, 13) == "##[group]run " then
				commandGroup += 1
			elseif commandGroup > 0 and lower:sub(1, 12) == "##[endgroup]" then
				commandGroup -= 1
			end
			if not inKey and commandGroup == 0 and #line <= MAX_LINE_BYTES then
				local annotation = lower:sub(1, 9) == "##[error]"
				local diagnostic = lower:find("%f[%a]error:") or lower:find("%f[%a]fatal:") or lower:find("^%s*failed[:%s]")
				local relevant = annotation and #ranges == 0
				if annotation or diagnostic then
					for _, range in ipairs(ranges) do
						if at >= range.start and at <= range.finish then relevant = true; break end
					end
				end
				if relevant and (annotation or not lower:find("##[", 1, true)) then
					local clean = redact(line)
					if lines[#lines] ~= clean then table.insert(lines, clean) end
					if #lines >= MAX_EXCERPT_LINES then break end
				end
			end
			if line:find("-----END", 1, true) then inKey = false end
		end
	end
	if #lines == 0 then return problem("no-relevant-excerpt", "日志可读，但没有可安全引用的相关失败诊断行。") end
	return { state = "available", lines = lines, truncated = true, redaction = "已裁剪日志，只保留少量诊断行，并隐藏可识别的凭据。" }
end

local function logProblem(p: Problem): any
	return { state = p.kind, reason = p.message }
end

local function failedSteps(job: any): { any }
	local steps: { any } = tern.json.array()
	if type(job.steps) == "table" then
		for _, step in ipairs(job.steps) do
			if type(step) == "table" and type(step.conclusion) == "string" and BAD[step.conclusion:upper()] then
				local name = text(step.name)
				table.insert(steps, {
					number = step.number, name = if name then redact(name) else nil, conclusion = step.conclusion,
					startedAt = step.started_at, completedAt = step.completed_at,
				})
			end
		end
	end
	return steps
end

local function checkNumber(value: any, repo: runtime.Repo): string?
	local path = repoPath(value, repo)
	return if path then path:match("^runs/([1-9]%d*)$") else nil
end

local function actionsJob(exec: runtime.Exec, repo: runtime.Repo, check: any, runId: string, done: Callback)
	local canonical = checkNumber(check.permalink, repo) or checkNumber(check.url, repo)
	if canonical then done(canonical, nil); return end
	local details = repoPath(check.detailsUrl, repo)
	if details then
		local linkRun, linkJob = details:match("^actions/runs/([1-9]%d*)/job/([1-9]%d*)$")
		if linkRun == runId and linkJob then
			-- A details URL is not itself proof that this is the exact check run.
			rest(exec, repo, "check-runs/" .. linkJob, function(data, err)
				if err then done(nil, err); return end
				if idText(data.id) == linkJob and data.node_id == check.id then
					done(linkJob, nil)
				else
					done(nil, problem("unverified", "Actions job 链接未能对应精确的失败检查。"))
				end
			end)
			return
		end
	end
	done(nil, problem("unverified", "无法核对失败检查对应的 Actions job。"))
end

local function runEvidence(repo: runtime.Repo, v: Version, run: any, runId: string): string?
	if idText(run.id) ~= runId or type(run.repository) ~= "table" or not sameName(run.repository.full_name, repoName(repo)) then
		return nil
	end
	local commit = sha(run.head_sha)
	return if commit == v.head or commit == v.merge then commit else nil
end

local function jobEvidence(repo: runtime.Repo, v: Version, check: any, job: any, runId: string, jobId: string): string?
	local checkUrl = text(job.check_run_url)
	local checkRepo = if checkUrl then checkUrl:match("/repos/([^/]+/[^/]+)/check%-runs/" .. jobId .. "$") else nil
	if idText(job.id) ~= jobId or idText(job.run_id) ~= runId or not sameName(checkRepo, repoName(repo))
		or job.status ~= "completed" or not sameName(job.conclusion, check.conclusion) then return nil end
	local commit = sha(job.head_sha)
	return if commit == v.head or commit == v.merge then commit else nil
end

local function enrichFailures(exec: runtime.Exec, repo: runtime.Repo, v: Version, checks: { any }, ci: any, done: () -> ())
	local logsRequested = 0
	type Cached = { data: any, err: Problem? }
	local workflows: { [string]: Cached } = {}
	local runs: { [string]: Cached } = {}
	local function workflowFor(id: string, receive: Callback)
		local cached = workflows[id]
		if cached then receive(cached.data, cached.err); return end
		graphql(exec, repo, WORKFLOW, { "-f", "id=" .. id }, function(data, err)
			local suite = data and data.node
			local workflow = if type(suite) == "table" and suite.id == id then suite.workflowRun else nil
			local path = if type(workflow) == "table" then repoPath(workflow.resourcePath, repo) else nil
			local runId = if path then path:match("^actions/runs/([1-9]%d*)$") else nil
			if not err and not runId then err = problem("unverified", "无法从检查套件核对 Actions run。") end
			workflows[id] = { data = runId, err = err }
			receive(runId, err)
		end)
	end
	local function runFor(id: string, receive: Callback)
		local cached = runs[id]
		if cached then receive(cached.data, cached.err); return end
		rest(exec, repo, "actions/runs/" .. id, function(data, err)
			runs[id] = { data = data, err = err }
			receive(data, err)
		end)
	end
	local function actions(check: any, suiteId: string, item: any, nextCheck: () -> ())
		local function unavailable(kind: string, message: string)
			item.log = { state = kind, reason = message }
			nextCheck()
		end
		workflowFor(suiteId, function(runId, associationError)
			if associationError then unavailable(associationError.kind, associationError.message); return end
			actionsJob(exec, repo, check, runId, function(jobId, checkError)
				if checkError then unavailable(checkError.kind, checkError.message); return end
				runFor(runId, function(run, runError)
					if runError then unavailable(runError.kind, runError.message); return end
					local runSha = runEvidence(repo, v, run, runId)
					if not runSha then
						unavailable("unverified", "Actions run 与目标仓库或 PR 版本不一致；未读取日志。")
						return
					end
					local endpoint = "actions/jobs/" .. jobId
					rest(exec, repo, endpoint, function(job, jobError)
						if jobError then unavailable(jobError.kind, jobError.message); return end
						local jobSha = jobEvidence(repo, v, check, job, runId, jobId)
						if not jobSha then
							unavailable("unverified", "Actions job 与失败检查、run 或 PR 版本不一致；未读取日志。")
							return
						end
						local combined = runSha ~= v.head or jobSha ~= v.head
						if combined and not mergeAssociation(run, v) then
							unavailable("unverified", "无法证明 Actions 测试合并提交对应当前 PR 版本；未读取日志。")
							return
						end
						local runName, jobName = text(run.name), text(job.name)
						item.run = { id = runId, url = sourceUrl(run.html_url), name = if runName then redact(runName) else nil, head = runSha, attempt = job.run_attempt }
						item.job = { id = jobId, url = sourceUrl(job.html_url), name = if jobName then redact(jobName) else nil, head = jobSha }
						item.versionEvidence = { head = v.head, testMerge = if combined then v.merge else nil, base = if combined then v.base else nil }
						item.failedSteps = failedSteps(job)
						if type(job.steps) ~= "table" then item.stepsIssue = problem("unknown", "GitHub 未返回 job 的步骤数据。") end
						if logsRequested >= MAX_LOG_JOBS then
							unavailable("limited", "任务的失败日志摘录配额已用完；可通过 job 链接查看。")
							return
						end
						logsRequested += 1
						-- gh otherwise rejects the whole log when it contains ANSI.
						-- The raw bytes stay in the process result, never in the view or materials.
						exec({ "gh", "api", "--hostname", repo.host, "--method", "GET", "--allow-escape-sequences",
							"repos/" .. repoName(repo) .. "/" .. endpoint .. "/logs" }, { timeout_ms = 15000 }, function(result, err)
							if result and result.status == 0 and not result.timed_out then
								local evidence = excerpt(result.stdout, item.failedSteps)
								item.log = if evidence.kind then logProblem(evidence) else evidence
							else
								item.log = logProblem(apiProblem(result, err, nil))
							end
							nextCheck()
						end)
					end)
				end)
			end)
		end)
	end
	local function load(start: number)
		for index = start, #checks do
			local check = checks[index]
			local legacy = check.__typename == "StatusContext"
			local name = text(if legacy then check.context else check.name)
			local item: any = {
				id = check.id,
				kind = if legacy then "status-context" else "check-run",
				name = if name then redact(name) else nil,
				url = sourceUrl(if legacy then check.targetUrl else check.url) or sourceUrl(check.detailsUrl),
				detailsUrl = if not legacy then sourceUrl(check.detailsUrl) else nil,
				state = if legacy then check.state else check.conclusion,
				startedAt = check.startedAt or check.createdAt,
				completedAt = check.completedAt,
			}
			if item.state == "CANCELLED" or item.state == "STALE" then
				item.note = "检查已取消或失效；不证明代码有错误。"
			end
			table.insert(ci.failedChecks, item)
			local suite = check.checkSuite
			local app = if type(suite) == "table" and type(suite.app) == "table" then text(suite.app.slug) else nil
			local suiteId = if type(suite) == "table" then text(suite.id) else nil
			if legacy or (app and app ~= "github-actions") then
				item.log = { state = "unsupported", reason = "该检查不提供可从 GitHub Actions 读取的日志；请查看检查链接。" }
			elseif not suiteId then
				item.log = { state = "unverified", reason = "检查没有可核对的 Actions 套件；未读取日志。" }
			else
				actions(check, suiteId, item, function() load(index + 1) end)
				return
			end
		end
		done()
	end
	load(1)
end

function materials.collect(exec: runtime.Exec, repo: runtime.Repo, kind: string, number: number, alive: () -> boolean, done: (data: any, error: string?) -> ())
	if (kind ~= "issue" and kind ~= "pr") or not validTarget(repo, number) then
		done(nil, "GitHub 任务身份无效。")
		return
	end
	local taskKind: Kind = kind
	local settled = false
	local function finish(data: any, err: string?)
		if settled then return end
		settled = true
		if not alive() then done(nil, "任务材料读取已取消。"); return end
		if data then data.fetchedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()) end
		done(data, err)
	end
	local function activeExec(argv: { string }, options: runtime.Options?, receive: (runtime.Result?, string?) -> ())
		if settled then return end
		if not alive() then finish(nil, nil); return end
		exec(argv, options, function(result, err)
			if settled then return end
			if not alive() then finish(nil, nil); return end
			receive(result, err)
		end)
	end
	graphql(activeExec, repo, if taskKind == "pr" then PR else ISSUE, taskFields(repo, number), function(data, err)
		if err then finish(nil, err.message); return end
		local identity, task = actual(repo, taskKind, number, data)
		if not identity or type(task.title) ~= "string" or type(task.body) ~= "string" then
			finish(nil, "无法核对 GitHub 任务身份或读取标题和正文。")
			return
		end
		local material: any = {
			identity = identity, url = sourceUrl(task.url), title = task.title, body = task.body,
			author = task.author, createdAt = task.createdAt, updatedAt = task.updatedAt,
		}
		if taskKind == "issue" then
			discussion(activeExec, repo, identity.id, function(comments, discussionError)
				if discussionError then finish(nil, "读取 Issue 讨论：" .. discussionError.message); return end
				material.discussion = comments
				finish(material, nil)
			end)
			return
		end
		local head = sha(task.headRefOid)
		if not head then finish(nil, "PR 没有可验证的 head SHA。"); return end
		material.head = head
		local mergeable = task.mergeable
		material.mergeability = {
			status = if mergeable == "CONFLICTING" or mergeable == "MERGEABLE" then mergeable else "UNKNOWN",
			head = head, base = sha(task.baseRefOid), baseRef = text(task.baseRefName),
		}
		local version = versionFor(task, head)
		overallReviews(activeExec, repo, identity.id, head, task.reviewDecision, function(overall, _reviewError)
			material.overallReviews = overall
			reviewThreads(activeExec, repo, identity.id, head, function(threads, reviewError)
				if reviewError then finish(nil, reviewError.message); return end
				material.reviewThreads = threads
				exactChecks(activeExec, repo, number, head, function(ci, checks)
					material.ci = ci
					enrichFailures(activeExec, repo, version, checks, ci, function()
						readHead(activeExec, repo, number, function(current, headError, id)
							if headError then finish(nil, "复核 PR 版本：" .. headError); return end
							if current ~= head or id ~= identity.id then
								finish(nil, "读取期间 PR head 已变化（" .. head .. " → " .. (current or "未知") .. "）；请刷新后重试。")
								return
							end
							finish(material, nil)
						end)
					end)
				end)
			end)
		end)
	end)
end

return materials
